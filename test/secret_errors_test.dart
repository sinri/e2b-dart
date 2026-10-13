import 'dart:convert';
import 'package:e2b/e2b.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('static Secret management uses supplied client and per-call options',
      () async {
    final requests = <http.Request>[];
    var missing = false;
    final client = ApiClient(
        apiKey: 'bound',
        httpClient: MockClient((request) async {
          requests.add(request);
          if (missing) return http.Response('{"message":"missing"}', 404);
          if (request.method == 'DELETE') return http.Response('', 204);
          return http.Response(
              jsonEncode({
                'secretID': 'id',
                'name': 'name',
                'currentVersion': 1,
                'createdAt': '2026-01-01T00:00:00Z',
                'updatedAt': '2026-01-01T00:00:00Z'
              }),
              200);
        }));
    addTearDown(client.close);
    final options = RequestOptions(apiKey: 'call');
    expect(
        (await Secret.create('name', 'value',
                client: client, options: options, metadata: {}))
            .secretId,
        'id');
    expect(
        (await Secret.update('name', 'next', client: client, options: options))
            .version,
        1);
    expect(
        (await Secret.getInfo('name', client: client, options: options)).name,
        'name');
    expect(
        await Secret.exists('name', client: client, options: options), isTrue);
    expect(
        await Secret.destroy('name', client: client, options: options), isTrue);
    missing = true;
    expect(
        await Secret.exists('name', client: client, options: options), isFalse);
    expect(await Secret.destroy('name', client: client, options: options),
        isFalse);
    expect(requests.every((r) => r.headers['X-API-Key'] == 'call'), isTrue);
    expect(jsonDecode(requests.first.body)['metadata'], isEmpty);
  });

  test('secret metadata omission differs from explicit replacement', () async {
    final requests = <http.Request>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(
              jsonEncode({
                'secretID': 'id',
                'name': 'name',
                'currentVersion': 1,
                'createdAt': '2026-01-01T00:00:00Z',
                'updatedAt': '2026-01-01T00:00:00Z'
              }),
              200);
        }));
    addTearDown(client.close);
    for (final metadata in [
      null,
      <String, String>{},
      {'team': 'sdk'}
    ]) {
      await client.secrets.create('', '', metadata: metadata);
      await client.secrets.update('name/a b', '', metadata: metadata);
      final create = jsonDecode(requests[requests.length - 2].body) as Map;
      final update = jsonDecode(requests.last.body) as Map;
      expect(create, {
        'name': '',
        'value': '',
        if (metadata != null) 'metadata': metadata
      });
      expect(update, {'value': '', if (metadata != null) 'metadata': metadata});
      expect(requests.last.url.pathSegments.last, 'name/a b');
    }
  });

  for (final status in [400, 401, 403, 404, 429, 500, 503]) {
    test('secret error mapping for CRUD and pagination status=$status',
        () async {
      final client = E2BClient(
          apiKey: 'key',
          retries: 0,
          httpClient: MockClient((_) async => http.Response(
              jsonEncode({'message': 'detail', 'code': 'permission_denied'}),
              status)));
      addTearDown(client.close);
      final Type type;
      final String message;
      switch (status) {
        case 401:
          type = AuthenticationException;
          message = 'Unauthorized, please check your credentials. - detail';
        case 429:
          type = RateLimitException;
          message = 'Rate limit exceeded, please try again later - detail';
        case 503:
          type = ServiceBusyException;
          message = 'Service temporarily unavailable, please retry - detail';
        default:
          type = SecretException;
          message = '$status: detail';
      }
      final generic = throwsA(isA<E2BException>()
          .having((e) => e.runtimeType, 'type', type)
          .having((e) => e.message, 'message', message));
      await expectLater(client.secrets.create('name', 'value'), generic);
      await expectLater(client.secrets.list().nextItems(), generic);
      if (status == 404) {
        final missing = throwsA(isA<SecretNotFoundException>()
            .having((e) => e.message, 'message', 'Secret name not found'));
        await expectLater(client.secrets.getInfo('name'), missing);
        await expectLater(client.secrets.update('name', 'value'), missing);
        expect(await client.secrets.exists('name'), isFalse);
        expect(await client.secrets.destroy('name'), isFalse);
      } else {
        await expectLater(client.secrets.getInfo('name'), generic);
        await expectLater(client.secrets.update('name', 'value'), generic);
        await expectLater(client.secrets.destroy('name'), generic);
      }
    });
  }
  test('secret required responses reject missing data', () async {
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((_) async => http.Response('', 204)));
    addTearDown(client.close);
    final missing = throwsA(isA<E2BException>()
        .having((e) => e.message, 'message', 'Response data is missing'));
    await expectLater(client.secrets.create('name', 'value'), missing);
    await expectLater(client.secrets.update('name', 'value'), missing);
    await expectLater(client.secrets.getInfo('name'), missing);
    expect(await client.secrets.list().nextItems(), isEmpty);
    expect(await client.secrets.destroy('name'), isTrue);
  });
}
