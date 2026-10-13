import 'dart:convert';
import 'dart:io';
import 'package:e2b/e2b.dart';
import 'package:test/test.dart';

void main() {
  test('Volume static default clients and instance content methods use HTTP',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <String>[];
    const info = {'volumeID': 'v', 'name': 'test', 'token': 'volume-token'};
    final serving = server.listen((request) async {
      requests.add('${request.method} ${request.uri.path}');
      final content = request.uri.path.startsWith('/volumecontent/');
      if (content) {
        expect(request.headers.value('authorization'), 'Bearer volume-token');
        expect(request.headers.value('x-api-key'), isNull);
      } else {
        expect(request.headers.value('x-api-key'), 'management-key');
      }
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'DELETE') {
        request.response.statusCode = 204;
      } else if (content) {
        final entry = {'path': '/a', 'name': 'a', 'type': 'file', 'size': 3};
        request.response.write(
            jsonEncode(request.uri.path.endsWith('/dir') ? [entry] : entry));
      } else if (request.method == 'GET' && request.uri.path == '/volumes') {
        request.response.write(jsonEncode([info]));
      } else {
        if (request.method == 'POST') {
          expect(jsonDecode(await utf8.decoder.bind(request).join()),
              {'name': 'test'});
        }
        request.response.write(jsonEncode(info));
      }
      await request.response.close();
    });
    addTearDown(() async {
      await serving.cancel();
      await server.close(force: true);
    });
    final origin = Uri.parse('http://127.0.0.1:${server.port}');
    final options = RequestOptions(apiKey: 'management-key', apiUrl: origin);
    final created = await Volume.create('test', options: options);
    final connected = await Volume.connect('v', options: options);
    try {
      expect(
          (await Volume.getInfo('v', options: options)).token, 'volume-token');
      expect((await Volume.list(options: options)).single.volumeId, 'v');
      expect(
          (await created.list('/',
                  options: VolumeRequestOptions(apiUrl: origin)))
              .single
              .path,
          '/a');
      expect(
          (await connected.getInfo('/a',
                  options: VolumeRequestOptions(apiUrl: origin)))
              .size,
          3);
      expect(await Volume.destroy('v', options: options), isTrue);
      expect(requests.length, 7);
    } finally {
      created.close();
      created.close();
      connected.close();
    }
  });
}
