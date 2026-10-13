// Run with all three *_INFLIGHT_REQUESTS variables set to 1. The corresponding
// connection limits stay above 1 so this checks shared admission, not sockets.
import 'dart:async';
import 'dart:io';
import 'package:e2b/e2b.dart';
import 'package:http/http.dart' as http;

Future<void> main() async {
  for (final scope in ['api', 'rest', 'rpc']) {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final release = Completer<void>();
    final arrived = Completer<void>();
    var requests = 0;
    server.listen((request) async {
      requests++;
      if (!arrived.isCompleted) arrived.complete();
      await release.future;
      request.response.write('ok');
      await request.response.close();
    });
    final first = ApiClient(apiKey: 'first', httpVersion: '1.1');
    final second = ApiClient(apiKey: 'second', httpVersion: '1.1');
    http.Client transport(ApiClient api) => switch (scope) {
          'rest' => api.envdHttpClientFor(null),
          'rpc' => api.envdHttpClientFor(null, rpc: true),
          _ => api.httpClient,
        };
    try {
      final a = transport(first);
      final b = transport(second);
      if (!identical(a, b)) throw StateError('$scope is not shared');
      final uri = Uri.parse('http://127.0.0.1:${server.port}/');
      final pendingA = a.get(uri);
      await arrived.future;
      first.close();
      final pendingB = b.get(uri);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (requests != 1) throw StateError('$scope bypassed shared limit');
      release.complete();
      final results = await Future.wait([pendingA, pendingB])
          .timeout(const Duration(seconds: 3));
      if (requests != 2 || results.any((response) => response.body != 'ok')) {
        throw StateError('$scope did not resume after releasing its slot');
      }
      print('$scope shared dispatch and root close passed');
    } finally {
      if (!release.isCompleted) release.complete();
      first.close();
      second.close();
      await server.close(force: true);
    }
  }
}
