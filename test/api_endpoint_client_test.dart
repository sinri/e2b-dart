import 'dart:convert';
import 'package:e2b/e2b.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('raw api returns HTTP errors while high-level requests still throw',
      () async {
    var status = 200;
    final client = ApiClient(
        apiKey: 'key',
        retries: 0,
        httpClient: MockClient(
            (_) async => http.Response('{"message":"detail"}', status)));
    addTearDown(client.close);
    expect(identical(client.api, client.api), isTrue);
    for (final code in [200, 400, 401, 404, 429, 500, 503]) {
      status = code;
      final result = await client.api.GET('/test');
      expect(result.response.statusCode, code);
      expect(code == 200 ? result.data : result.error, {'message': 'detail'});
      expect(code == 200 ? result.error : result.data, isNull);
      if (code != 200) {
        await expectLater(
            client.request('GET', '/test'), throwsA(isA<E2BException>()));
      }
    }
  });

  test('raw api encodes path and query and supports JSON body values',
      () async {
    final requests = <http.Request>[];
    final client = ApiClient(
        apiKey: 'key',
        retries: 0,
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('[1,2]', 200);
        }));
    addTearDown(client.close);
    final result =
        await client.api.GET('/sandboxes/{sandboxID}', pathParameters: {
      'sandboxID': 'a/b ?'
    }, query: {
      'state': ['running', 'paused'],
      'limit': 2,
      'omit': null
    });
    expect(result.data, [1, 2]);
    expect(requests.first.url.toString(), contains('/sandboxes/a%2Fb%20%3F'));
    expect(requests.first.url.queryParameters,
        {'state': 'running,paused', 'limit': '2'});
    expect(requests.first.headers['content-type'], isNull);
    for (final method in [
      'POST',
      'PUT',
      'PATCH',
      'DELETE',
      'OPTIONS',
      'TRACE'
    ]) {
      await client.api.request(method, '/test', body: [true, 1, 'text']);
      expect(requests.last.method, method);
      expect(jsonDecode(requests.last.body), [true, 1, 'text']);
      expect(requests.last.headers['content-type'], 'application/json');
    }
    await client.api.POST('/test', body: {'a': 1});
    await client.api.PUT('/test');
    await client.api.PATCH('/test');
    await client.api.DELETE('/test');
    await client.api.OPTIONS('/test');
    await client.api.TRACE('/test');
  });

  test('raw api empty/HEAD results and malformed JSON', () async {
    var body = '';
    var status = 204;
    final client = ApiClient(
        apiKey: 'key',
        retries: 0,
        httpClient: MockClient((_) async => http.Response(body, status)));
    addTearDown(client.close);
    expect((await client.api.GET('/test')).data, isNull);
    status = 404;
    expect((await client.api.GET('/test')).error, '');
    body = 'not json';
    status = 200;
    expect((await client.api.HEAD('/test')).data, isNull);
    await expectLater(client.api.GET('/test'), throwsFormatException);
  });
}
