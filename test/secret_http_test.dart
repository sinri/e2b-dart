import 'dart:convert';
import 'dart:io';
import 'package:e2b/e2b.dart';
import 'package:test/test.dart';

void main() {
  test(
      'static secrets use owned clients over real HTTP and retry page failures',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var pages = 0;
    final paths = <String>[];
    final keys = <String?>[];
    final info = {
      'secretID': 'id',
      'name': 'name/a b',
      'currentVersion': 1,
      'createdAt': '2026-01-01T00:00:00Z',
      'updatedAt': '2026-01-01T00:00:00Z'
    };
    final serving = server.listen((request) async {
      paths.add(request.uri.pathSegments.last);
      keys.add(request.headers.value('x-api-key'));
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/secrets' && request.method == 'GET') {
        pages++;
        expect(request.uri.queryParameters['limit'], '1');
        expect(request.uri.queryParameters['nextToken'],
            pages == 1 ? 'initial' : 'next');
        if (pages == 2) {
          request.response.statusCode = 403;
          request.response.write(jsonEncode({'message': 'retry'}));
        } else {
          if (pages == 1) request.response.headers.set('x-next-token', 'next');
          request.response.write(jsonEncode([info]));
        }
      } else if (request.method == 'DELETE') {
        request.response.statusCode = 204;
      } else {
        await request.drain<void>();
        request.response.write(jsonEncode(info));
      }
      await request.response.close();
    });
    addTearDown(serving.cancel);
    final options = RequestOptions(
        apiKey: 'bound',
        apiUrl: Uri.parse('http://127.0.0.1:${server.port}'),
        retries: 0);
    expect(
        (await Secret.create('name/a b', 'value', options: options)).secretId,
        'id');
    expect(
        (await Secret.update('name/a b', 'new', options: options)).version, 1);
    expect(await Secret.exists('name/a b', options: options), isTrue);
    expect(await Secret.destroy('name/a b', options: options), isTrue);
    final pagesList =
        Secret.list(limit: 1, nextToken: 'initial', options: options);
    expect((await pagesList.nextItems()).single.name, 'name/a b');
    await expectLater(pagesList.nextItems(), throwsA(isA<SecretException>()));
    expect(pagesList.nextToken, 'next');
    expect(
        (await pagesList.nextItems(options: RequestOptions(apiKey: 'call')))
            .single
            .secretId,
        'id');
    expect(pagesList.hasNext, isFalse);
    expect(paths.take(4), ['secrets', 'name/a b', 'name/a b', 'name/a b']);
    expect(keys.take(6).every((key) => key == 'bound'), isTrue);
    expect(keys.last, 'call');
  });
}
