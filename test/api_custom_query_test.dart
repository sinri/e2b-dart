import 'package:e2b/e2b.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('custom query callback bypasses defaults on every method', () async {
    final urls = <String>[];
    final client = ApiClient(
        apiKey: 'key',
        apiUrl: Uri.parse('https://example.test'),
        httpClient: MockClient((request) async {
          urls.add(request.url.toString());
          return http.Response('{}', 200);
        }));
    final query = <String, Object?>{
      'nested': {
        'list': [1, 2]
      }
    };
    var calls = 0;
    String serialize(Map<String, Object?> value) {
      expect(identical(value, query), isTrue);
      calls++;
      return '?custom=1%2C2&custom=3';
    }

    try {
      for (final method in [client.api.GET, client.api.HEAD]) {
        await method('/test', query: query, querySerializer: serialize);
      }
      for (final method in [
        client.api.POST,
        client.api.PUT,
        client.api.PATCH,
        client.api.DELETE,
        client.api.OPTIONS,
        client.api.TRACE
      ]) {
        await method('/test', query: query, querySerializer: serialize);
      }
      expect(calls, 8);
      expect(urls,
          everyElement('https://example.test/test?custom=1%2C2&custom=3'));
      await client.api.GET('/test', querySerializer: (_) => '?');
      expect(urls.last, 'https://example.test/test');
      final failure = StateError('serializer failed');
      await expectLater(
          client.api.GET('/test', querySerializer: (_) => throw failure),
          throwsA(same(failure)));
      expect(urls.length, 9);
      await client.api.GET('/test', query: {
        'state': ['running', 'paused']
      });
      expect(urls.last, 'https://example.test/test?state=running,paused');
    } finally {
      client.close();
    }
  });
}
