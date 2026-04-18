import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:viam_provisioner/core/http_server.dart';

void main() {
  test('serves real http-server/ tree end-to-end', () async {
    // flutter test runs from the app/ directory; repo root is its parent.
    final docRoot =
        p.normalize(p.join(Directory.current.path, '..', 'http-server'));
    expect(Directory(docRoot).existsSync(), isTrue,
        reason: 'Expected http-server/ at $docRoot');

    final server = EmbeddedHttpServer(docRoot: docRoot, port: 18299);
    await server.start();
    try {
      final client = HttpClient();
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:18299/autoinstall/meta-data'));
      final res = await req.close();
      // meta-data is the cloud-init sentinel file — must exist but
      // may be zero bytes.
      expect(res.statusCode, 200);
      expect(res.headers.contentType?.mimeType, 'text/plain');
      await res.drain();
      client.close();
    } finally {
      await server.stop();
    }
  });
}
