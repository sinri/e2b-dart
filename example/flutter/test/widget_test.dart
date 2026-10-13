import 'dart:convert';
import 'package:e2b/e2b.dart';
import 'package:e2b_flutter_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('creates a sandbox through the SDK and shows its ID',
      (tester) async {
    var requests = 0;
    final client = E2BClient(
        apiKey: 'test-only',
        httpClient: MockClient((request) async {
          requests++;
          expect(request.method, 'POST');
          expect(request.url.path, '/v2/sandboxes');
          expect(request.headers['x-api-key'], 'test-only');
          return http.Response(
              jsonEncode({
                'sandboxID': 'flutter-sandbox',
                'envdVersion': '0.6.4',
                'domain': 'e2b.app',
                'envdAccessToken': 'test-token'
              }),
              201,
              headers: {'content-type': 'application/json'});
        }));
    addTearDown(client.close);
    await tester.pumpWidget(E2BExample(client: client));
    await tester.tap(find.text('Create sandbox'));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(find.text('Sandbox: flutter-sandbox'), findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((w) => w.data)
            .join(' | '));
  });

  testWidgets('without client the creation button is disabled', (tester) async {
    await tester.pumpWidget(const E2BExample());
    expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNull);
  });
}
