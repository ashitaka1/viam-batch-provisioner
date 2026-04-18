import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Embedded HTTP server that mirrors the CLI's nginx container.
/// Serves the `http-server/` directory on [port] so PXE clients can fetch
/// the Ubuntu kernel/initrd, autoinstall configs, and per-machine credentials.
class EmbeddedHttpServer {
  EmbeddedHttpServer({required this.docRoot, this.port = 8234});

  final String docRoot;
  final int port;

  HttpServer? _server;
  final _requestLog = StreamController<String>.broadcast();

  Stream<String> get requests => _requestLog.stream;
  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server = server;
    server.listen(_handle, onError: (_) {});
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final requestPath = Uri.decodeComponent(req.uri.path);
    _requestLog.add('${req.method} $requestPath');

    // Resolve against docRoot, guard against path traversal.
    final safe = p.normalize(p.join(docRoot, requestPath.replaceFirst(RegExp(r'^/+'), '')));
    if (!p.isWithin(docRoot, safe) && p.canonicalize(safe) != p.canonicalize(docRoot)) {
      await _respond(req, HttpStatus.forbidden, 'Forbidden');
      return;
    }

    final file = File(safe);
    if (await file.exists()) {
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.contentType = _mimeFor(safe);
      req.response.headers.contentLength = await file.length();
      await file.openRead().pipe(req.response);
      return;
    }

    final dir = Directory(safe);
    if (await dir.exists()) {
      final index = File(p.join(safe, 'index.html'));
      if (await index.exists()) {
        req.response.headers.contentType = ContentType.html;
        await index.openRead().pipe(req.response);
        return;
      }
      await _respondDirListing(req, dir, requestPath);
      return;
    }

    await _respond(req, HttpStatus.notFound, 'Not found');
  }

  Future<void> _respond(HttpRequest req, int status, String body) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.text;
    req.response.write(body);
    await req.response.close();
  }

  Future<void> _respondDirListing(
    HttpRequest req,
    Directory dir,
    String requestPath,
  ) async {
    final entries = await dir.list().toList();
    entries.sort((a, b) => a.path.compareTo(b.path));
    final buf = StringBuffer()
      ..writeln('<html><body><h1>${_escape(requestPath)}</h1><ul>');
    for (final e in entries) {
      final name = p.basename(e.path);
      final slash = e is Directory ? '/' : '';
      buf.writeln('<li><a href="$name$slash">$name$slash</a></li>');
    }
    buf.writeln('</ul></body></html>');
    req.response.headers.contentType = ContentType.html;
    req.response.write(buf.toString());
    await req.response.close();
  }

  static String _escape(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  static ContentType _mimeFor(String path) {
    final ext = p.extension(path).toLowerCase();
    return switch (ext) {
      '.yaml' || '.yml' => ContentType('text', 'yaml'),
      '.json' => ContentType.json,
      '.html' || '.htm' => ContentType.html,
      '.txt' || '.cfg' || '.conf' => ContentType.text,
      '.sh' => ContentType('application', 'x-sh'),
      '.iso' || '.img' => ContentType('application', 'octet-stream'),
      '' => ContentType.text,
      _ => ContentType.binary,
    };
  }

  void dispose() {
    _requestLog.close();
    stop();
  }
}
