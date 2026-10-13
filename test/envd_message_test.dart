import 'dart:convert';
import 'dart:io';
import 'package:e2b/e2b.dart';
import 'package:e2b/src/envd_api_error.dart';
import 'package:test/test.dart';

void main() {
  test('envd JSON message truthiness and coercion match official extractor',
      () {
    final data =
        jsonDecode(File('test/envd_message_vectors.json').readAsStringSync())
            as Map;
    for (final vector in data['vectors'] as List) {
      for (final status in [400, 401, 404, 429, 507, 500]) {
        final error =
            envdApiError(status, vector['body'], 'Fallback') as E2BException;
        final expected = vector['expected'] as String;
        expect(
            error.message,
            status == 429
                ? '$expected: The requests are being rate limited.'
                : status == 500
                    ? '500: $expected'
                    : expected,
            reason: 'status=$status body=${vector['body']}');
      }
    }
  });
}
