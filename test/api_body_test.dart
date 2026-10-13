import 'dart:convert';
import 'dart:io';
import 'package:e2b/e2b.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('form body matches actual pinned official serializer', () async {
    final vectors =
        (jsonDecode(File('test/api_body_vectors.json').readAsStringSync())
            as Map)['vectors'] as List;
    for (final row in vectors) {
      final client = ApiClient(
          apiKey: 'key',
          httpClient: MockClient((request) async {
            expect(request.body, row['text']);
            expect(request.headers['content-type'],
                startsWith('application/x-www-form-urlencoded'));
            return http.Response('{}', 200);
          }));
      try {
        final pending = client.api.POST('/test',
            body: row['body'],
            options: RequestOptions(headers: {
              'Content-Type': 'application/x-www-form-urlencoded'
            }));
        if (row['error'] != null) {
          await expectLater(pending, throwsArgumentError);
        } else {
          await pending;
        }
      } finally {
        client.close();
      }
    }
  });
  test('custom body serializer sends raw bytes and does not leak between calls',
      () async {
    final bodies = <List<int>>[];
    final client = ApiClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          bodies.add(request.bodyBytes);
          return http.Response('{}', 200);
        }));
    try {
      await client.api.POST('/test', body: {'value': 1},
          bodySerializer: (body, headers) {
        expect(headers['x-test'], 'yes');
        return [0, 128, 255];
      }, options: RequestOptions(headers: {'X-Test': 'yes'}));
      await client.api
          .PUT('/test', body: 'text', bodySerializer: (_, __) => 'raw');
      await client.api
          .PATCH('/test', body: {'value': 2}, bodySerializer: (_, __) => null);
      await client.api.POST('/test', body: {'value': 3});
      expect(bodies, [
        [0, 128, 255],
        utf8.encode('raw'),
        [],
        utf8.encode('{"value":3}')
      ]);
      final reason = StateError('serialize failed');
      await expectLater(
          client.api
              .POST('/test', body: {}, bodySerializer: (_, __) => throw reason),
          throwsA(same(reason)));
      expect(bodies.length, 4);
    } finally {
      client.close();
    }
  });
}
