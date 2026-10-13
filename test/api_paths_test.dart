import 'dart:convert';
import 'package:e2b/e2b.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('component response views preserve errors and wire headers', () {
    final response = ApiResponse(
        error: {'code': 429, 'message': 'slow down'},
        response: http.Response('', 429,
            headers: {'retry-after': '2.5', 'x-custom': 'kept'}));
    final typed = ApiComponentResponse429(response);
    expect(typed.content.code, 429);
    expect(typed.content.message, 'slow down');
    expect(typed.retryAfterSeconds, 2.5);
    expect(typed.headers['x-custom'], 'kept');
    expect(() => ApiComponentResponse400(response), throwsArgumentError);
    final dateHeader = ApiComponentResponse429(ApiResponse(
        error: {},
        response: http.Response('', 429,
            headers: {'retry-after': 'Wed, 21 Oct 2026 07:28:00 GMT'})));
    expect(dateHeader.retryAfterSeconds, isNull);
    expect(dateHeader.headers['retry-after'], contains('GMT'));
    final malformed = ApiComponentResponse503(
        ApiResponse(error: 'unavailable', response: http.Response('', 503)));
    expect(() => malformed.content, throwsFormatException);
    const ApiComponentParameterPaginationLimit limit = 1.5;
    const ApiComponentHeaderXTotalRunning total = 3;
    const ApiComponentHeaderXNextToken next = 'cursor';
    expect([limit, total, next], [1.5, 3, 'cursor']);
  });

  test('typed bindings forward all serializer callbacks in official order',
      () async {
    final events = <String>[];
    final body = ApiSchemaNewSandboxV2(templateID: 'base');
    final client = ApiClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          events.add('fetch');
          expect(request.url.toString(), 'https://api.e2b.app/custom?forced=1');
          expect(request.body, 'custom-body');
          return http.Response('{"sandboxID":"typed"}', 201);
        }));
    try {
      final response = await ApiPaths.postV2Sandboxes(client.api, body: body,
          bodySerializer: (value, headers) {
        events.add('body');
        expect(identical(value, body), isTrue);
        return 'custom-body';
      }, pathSerializer: (url, parameters) {
        events.add('path');
        expect(parameters, isEmpty);
        return url.replaceAll('/v2/sandboxes', '/custom');
      }, querySerializer: (parameters) {
        events.add('query');
        expect(parameters, isEmpty);
        return '?forced=1';
      });
      expect(response.data!.sandboxID, 'typed');
      expect(events, ['body', 'path', 'query', 'fetch']);
    } finally {
      client.close();
    }
  });

  test('typed create binds method/body and decodes success model', () async {
    final client = ApiClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/v2/sandboxes');
          expect(
              jsonDecode(request.body), {'templateID': 'base', 'timeout': 60});
          expect(request.headers['X-API-Key'], 'override');
          return http.Response(
              '{"sandboxID":"sandbox","envdVersion":"0.6.4"}', 201);
        }));
    try {
      final ApiTypedResponse<ApiSchemaSandbox> response =
          await ApiPaths.postV2Sandboxes(client.api,
              body: ApiSchemaNewSandboxV2(templateID: 'base', timeout: 60),
              options: RequestOptions(apiKey: 'override'));
      expect(response.data!.sandboxID, 'sandbox');
      expect(response.data!.envdVersion, '0.6.4');
      expect(response.error, isNull);
      expect(response.raw.response.statusCode, 201);
    } finally {
      client.close();
    }
  });

  test('typed list preserves query serialization and pagination headers',
      () async {
    final client = ApiClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/v2/sandboxes');
          expect(request.url.queryParameters,
              {'state': 'running,paused', 'limit': '0', 'nextToken': 'a b'});
          return http.Response('[{"sandboxID":"one"},{"sandboxID":"two"}]', 200,
              headers: {'x-next-token': 'next'});
        }));
    try {
      final response = await ApiPaths.getV2Sandboxes(client.api,
          state: ['running', 'paused'], limit: 0, nextToken: 'a b');
      expect(response.data!.map((item) => item.sandboxID), ['one', 'two']);
      expect(response.raw.response.headers['x-next-token'], 'next');
    } finally {
      client.close();
    }
  });

  test(
      'typed path encodes IDs and returns HTTP errors without decoding success',
      () async {
    var calls = 0;
    final client = ApiClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          expect(request.method, 'DELETE');
          expect(request.url.toString(),
              'https://api.e2b.app/volumes/a%2Fb%20%E4%B8%AD');
          return ++calls == 1
              ? http.Response('', 204)
              : http.Response('{"code":403,"message":"denied"}', 403);
        }));
    try {
      final success =
          await ApiPaths.deleteVolumesVolumeID(client.api, volumeID: 'a/b 中');
      expect(success.data, isNull);
      expect(success.error, isNull);
      final failure =
          await ApiPaths.deleteVolumesVolumeID(client.api, volumeID: 'a/b 中');
      expect(failure.data, isNull);
      expect(failure.error, {'code': 403, 'message': 'denied'});
      expect(failure.raw.response.statusCode, 403);
    } finally {
      client.close();
    }
  });

  test('optional typed body omits absent body and encodes provided body',
      () async {
    final bodies = <String>[];
    final client = ApiClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          bodies.add(request.body);
          expect(request.url.path, '/sandboxes/sandbox/fork');
          return http.Response('[{"sandbox":{"sandboxID":"child"}}]', 201);
        }));
    try {
      final response = await ApiPaths.postSandboxesSandboxIDFork(client.api,
          sandboxID: 'sandbox');
      expect(response.data!.single.sandbox!.sandboxID, 'child');
      await ApiPaths.postSandboxesSandboxIDFork(client.api,
          sandboxID: 'sandbox', body: ApiSchemaSandboxForkRequest(count: 2));
      expect(bodies, ['', '{"count":2}']);
    } finally {
      client.close();
    }
  });
}
