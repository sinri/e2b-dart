// Local real-HTTP check; run with E2B_API_INFLIGHT_REQUESTS=1 and =0.
import 'dart:async';
import 'dart:io';
import 'package:e2b/src/http_client_io.dart';

Future<void> main() async {
  final disabled = Platform.environment['E2B_API_INFLIGHT_REQUESTS'] == '0' &&
      Platform.environment['E2B_API_CONNECTIONS'] != '1';
  for (final proxy in [false, true]) {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final release = Completer<void>();
    final arrived = Completer<void>();
    var requests = 0;
    final tunnels = <Socket>[];
    server.listen((request) async {
      if (request.method == 'CONNECT') {
        final upstream = await Socket.connect('127.0.0.1', server.port);
        request.response.statusCode = 200;
        request.response.contentLength = 0;
        final downstream = await request.response.detachSocket();
        tunnels.addAll([upstream, downstream]);
        unawaited(upstream.addStream(downstream).then((_) => upstream.close(),
            onError: (Object _) {
          upstream.destroy();
        }));
        unawaited(downstream.addStream(upstream).then((_) => downstream.close(),
            onError: (Object _) {
          downstream.destroy();
        }));
        return;
      }
      requests++;
      if (!arrived.isCompleted) arrived.complete();
      await release.future;
      request.response.write('ok');
      await request.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}';
    final client = createHttpClient(proxy ? url : null, httpVersion: '1.1');
    try {
      final target =
          Uri.parse(proxy ? 'http://origin.invalid/test' : '$url/test');
      final first = client.get(target);
      await arrived.future;
      final second = client.get(target);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (requests != (disabled ? 2 : 1)) {
        throw StateError('proxy=$proxy disabled=$disabled requests=$requests');
      }
      release.complete();
      await Future.wait([first, second]).timeout(const Duration(seconds: 5));
      if (requests != 2) throw StateError('queued request was not dispatched');
    } finally {
      if (!release.isCompleted) release.complete();
      client.close();
      for (final socket in tunnels) {
        socket.destroy();
      }
      await server.close(force: true);
    }
  }
  print('HTTP/1.1 direct and proxy inflight limit passed: disabled=$disabled');
}
