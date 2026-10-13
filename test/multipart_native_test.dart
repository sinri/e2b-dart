import 'dart:convert';
import 'dart:io';
import 'package:e2b/src/http2_client_io.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  test(
      'native multipart sends finalize-generated content type on HTTP fallback',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var received = 0;
    final serving = server.listen((request) async {
      final type = request.headers.contentType;
      expect(type?.mimeType, 'multipart/form-data');
      expect(type?.parameters['boundary'], isNotEmpty);
      final bytes =
          await request.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
      final text = latin1.decode(bytes);
      expect(text, contains('filename="/data.bin"'));
      expect(text, contains(latin1.decode([0, 128, 255])));
      received++;
      request.response.write('ok');
      await request.response.close();
    });
    try {
      for (final allowH2 in [false, true]) {
        final client = Http2Client(allowH2: allowH2);
        try {
          final request = http.MultipartRequest(
              'POST', Uri.parse('http://127.0.0.1:${server.port}/files'))
            ..files.add(http.MultipartFile.fromBytes('file', [0, 128, 255],
                filename: '/data.bin'));
          expect(request.headers['content-type'], isNull);
          expect(
              (await http.Response.fromStream(await client.send(request))).body,
              'ok');
        } finally {
          client.close();
        }
      }
      expect(received, 2);
    } finally {
      await serving.cancel();
      await server.close(force: true);
    }
  });
}
