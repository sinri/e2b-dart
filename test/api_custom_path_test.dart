import 'package:e2b/e2b.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('serializers run body then path then query and stop on failure',
      () async {
    final events = <String>[];
    final client = ApiClient(
        apiKey: 'key',
        httpClient: MockClient((_) async {
          events.add('fetch');
          return http.Response('{}', 200);
        }));
    final failure = StateError('serializer');
    try {
      for (final failAt in ['', 'body', 'path', 'query']) {
        events.clear();
        String record(String name, String result) {
          events.add(name);
          if (failAt == name) throw failure;
          return result;
        }

        final operation = client.api.POST('/test',
            body: {'x': 1},
            bodySerializer: (_, __) => record('body', '{}'),
            pathSerializer: (url, _) => record('path', url),
            querySerializer: (_) => record('query', 'a=b'));
        if (failAt.isEmpty) {
          await operation;
          expect(events, ['body', 'path', 'query', 'fetch']);
        } else {
          await expectLater(operation, throwsA(same(failure)));
          expect(
              events,
              ['body', 'path', 'query']
                  .take(['body', 'path', 'query'].indexOf(failAt) + 1)
                  .toList());
        }
      }
    } finally {
      client.close();
    }
  });

  test('query appends to serialized path before URI parsing', () async {
    final urls = <String>[];
    final client = ApiClient(
        apiKey: 'key',
        apiUrl: Uri.parse('https://bound.test/base/'),
        httpClient: MockClient((request) async {
          urls.add(request.url.toString());
          return http.Response('{}', 200);
        }));
    try {
      for (final suffix in ['x?kept=1', 'x#fragment', 'x?kept=1#fragment']) {
        await client.api.GET('/items/{id}',
            pathParameters: {'id': 'x'},
            query: {'a': 'b'},
            pathSerializer: (url, _) => url.replaceAll('{id}', suffix));
      }
      expect(urls, [
        'https://bound.test/base/items/x?kept=1?a=b',
        'https://bound.test/base/items/x#fragment?a=b',
        'https://bound.test/base/items/x?kept=1#fragment?a=b'
      ]);
    } finally {
      client.close();
    }
  });

  test('custom path callback receives full override URL and raw params',
      () async {
    final urls = <String>[];
    final client = ApiClient(
        apiKey: 'key',
        apiUrl: Uri.parse('https://bound.test/base/'),
        httpClient: MockClient((request) async {
          urls.add(request.url.toString());
          return http.Response('{}', 200);
        }));
    final params = <String, Object?>{
      'id': {'nested': true}
    };
    try {
      await client.api.POST('/items/{id}',
          pathParameters: params,
          options: RequestOptions(apiUrl: Uri.parse('https://call.test/v1/')),
          pathSerializer: (url, values) {
        expect(url, 'https://call.test/v1/items/{id}');
        expect(identical(values, params), isTrue);
        return url.replaceAll('{id}', 'custom');
      }, query: {'a': 'b'});
      expect(urls.single, 'https://call.test/v1/items/custom?a=b');
      await client.api.GET('/items/{id}',
          pathSerializer: (url, _) => url.replaceAll('{id}', 'x?kept=1'));
      expect(urls.last, 'https://bound.test/base/items/x?kept=1');
      final failure = StateError('path failed');
      await expectLater(
          client.api.GET('/test', pathSerializer: (_, __) => throw failure),
          throwsA(same(failure)));
      expect(urls.length, 2);
      await client.api.GET('/items/{id}', pathParameters: {'id': 'ordinary'});
      expect(urls.last, 'https://bound.test/base/items/ordinary');
    } finally {
      client.close();
    }
  });
}
