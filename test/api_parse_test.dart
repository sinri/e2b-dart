import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:e2b/e2b.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('raw response parsing matches pinned openapi-fetch execution', () async {
    final vectors =
        (jsonDecode(File('test/api_parse_vectors.json').readAsStringSync())
            as Map)['vectors'] as List;
    for (final vector in vectors) {
      final client = ApiClient(
          apiKey: 'key',
          retries: 0,
          httpClient: MockClient((_) async => http.Response(
              vector['body'] as String, vector['status'] as int,
              headers: Map<String, String>.from(vector['headers'] as Map))));
      try {
        final pending = client.api.request(vector['method'] as String, '/test',
            parseAs: vector['parseAs'] as String);
        if (vector['kind'] == 'throws') {
          await expectLater(pending, throwsFormatException, reason: '$vector');
        } else {
          final result = await pending;
          final value =
              (vector['status'] as int) < 300 ? result.data : result.error;
          if (vector['kind'] == 'bytes') expect(value, isA<Uint8List>());
          expect(value, vector['expected'], reason: '$vector');
        }
      } finally {
        client.close();
      }
    }
  });

  test('raw request uppercases methods and reads text as UTF8', () async {
    final client = ApiClient(
        apiKey: 'key',
        retries: 0,
        httpClient: MockClient((request) async {
          expect(request.method, 'GET');
          return http.Response.bytes(utf8.encode('世界'), 200,
              headers: {'content-type': 'text/plain; charset=iso-8859-1'});
        }));
    addTearDown(client.close);
    expect(
        (await client.api.request('get', '/test', parseAs: 'text')).data, '世界');
    expect((await client.api.GET('/test', parseAs: 'arrayBuffer')).data,
        utf8.encode('世界'));
  });
}
