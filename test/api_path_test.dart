import 'dart:convert';
import 'dart:io';
import 'package:e2b/e2b.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test(
      'raw path serialization matches pinned URLs after Dart URI canonicalization',
      () async {
    final vectors =
        (jsonDecode(File('test/api_path_vectors.json').readAsStringSync())
            as Map)['vectors'] as List;
    for (final vector in vectors) {
      String? url;
      final client = ApiClient(
          apiKey: 'key',
          apiUrl: Uri.parse('https://example.test'),
          retries: 0,
          httpClient: MockClient((request) async {
            url = request.url.toString();
            return http.Response('{}', 200);
          }));
      try {
        final pending = client.api.GET(vector['path'] as String,
            pathParameters:
                Map<String, Object?>.from(vector['parameters'] as Map));
        if (vector['error'] != null) {
          await expectLater(
              pending,
              throwsA(isA<StateError>().having(
                  (error) => error.message, 'message', vector['error'])));
          expect(url, isNull);
        } else {
          await pending;
          expect(url, Uri.parse(vector['url'] as String).toString(),
              reason: '${vector['parameters']}');
        }
      } finally {
        client.close();
      }
    }
  });
}
