import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:viam_provisioner/core/http_server.dart';

void main() {
  late Directory tmp;
  late EmbeddedHttpServer server;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('http_server_test');
    await Directory(p.join(tmp.path, 'autoinstall')).create();
    await File(p.join(tmp.path, 'autoinstall', 'meta-data'))
        .writeAsString('instance-id: pxe\n');
    await File(p.join(tmp.path, 'autoinstall', 'user-data'))
        .writeAsString('#cloud-config\nhostname: demo\n');
    server = EmbeddedHttpServer(docRoot: tmp.path, port: 0);
  });

  tearDown(() async {
    await server.stop();
    await tmp.delete(recursive: true);
  });

  test('serves extension-less files as plain text', () async {
    final realServer = EmbeddedHttpServer(docRoot: tmp.path, port: 18234);
    await realServer.start();
    try {
      final client = HttpClient();
      final req =
          await client.getUrl(Uri.parse('http://127.0.0.1:18234/autoinstall/meta-data'));
      final res = await req.close();
      expect(res.statusCode, 200);
      expect(res.headers.contentType?.mimeType, 'text/plain');
      final body = await res.transform(utf8.decoder).join();
      expect(body, contains('instance-id: pxe'));
      client.close();
    } finally {
      await realServer.stop();
    }
  });

  test('404 for missing file', () async {
    final realServer = EmbeddedHttpServer(docRoot: tmp.path, port: 18235);
    await realServer.start();
    try {
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:18235/nope'));
      final res = await req.close();
      expect(res.statusCode, 404);
      await res.drain();
      client.close();
    } finally {
      await realServer.stop();
    }
  });

  test('rejects path traversal', () async {
    final realServer = EmbeddedHttpServer(docRoot: tmp.path, port: 18236);
    await realServer.start();
    try {
      final client = HttpClient();
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:18236/../../../../etc/passwd'),
      );
      final res = await req.close();
      expect(res.statusCode, anyOf(403, 404));
      await res.drain();
      client.close();
    } finally {
      await realServer.stop();
    }
  });
}
