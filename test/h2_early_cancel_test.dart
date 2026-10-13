import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:e2b/e2b.dart';
import 'package:e2b/src/http2_client_io.dart';
import 'package:http2/transport.dart';
import 'package:test/test.dart';

void main() {
  test('early h2 cancellation preserves session and HPACK context', () async {
    final context = SecurityContext()
      ..useCertificateChain('test/fixtures/http2-local-cert.pem')
      ..usePrivateKey('test/fixtures/http2-local-key.pem')
      ..setAlpnProtocols(['h2'], true);
    final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4, 0, context,
        supportedProtocols: ['h2']);
    final connections = <ServerTransportConnection>[];
    final ids = <int>[];
    final ready = Completer<void>();
    final reset = Completer<void>();
    var healthRequests = 0;
    var closing = false;
    server.listen((socket) {
      expect(socket.selectedProtocol, 'h2');
      final connection = ServerTransportConnection.viaSocket(socket);
      connections.add(connection);
      connection.incomingStreams.listen((stream) async {
        final messages = await stream.incomingMessages.toList();
        final headers = {
          for (final header
              in messages.whereType<HeadersStreamMessage>().first.headers)
            utf8.decode(header.name): utf8.decode(header.value)
        };
        ids.add(stream.id);
        if (headers[':path']!.endsWith('/connect')) {
          expect(headers['x-api-key'], 'management-key');
          stream.sendHeaders([
            Header.ascii(':status', '200'),
            Header.ascii('content-type', 'application/json')
          ]);
          stream.sendData(
              utf8.encode(jsonEncode({
                'sandboxID': 'sb',
                'envdVersion': '0.6.4',
                'envdAccessToken': 'envd-token'
              })),
              endStream: true);
          return;
        }
        expect(headers[':path'], '/health');
        expect(headers['x-access-token'], 'envd-token');
        expect(headers['x-api-key'], isNull);
        healthRequests++;
        if (healthRequests == 1) {
          stream.onTerminated = (_) {
            if (!reset.isCompleted) reset.complete();
          };
          stream.sendHeaders([
            Header.ascii(':status', '200'),
            Header.ascii('x-late-state', 'shared-dynamic-value')
          ]);
          stream.sendData([120]);
          ready.complete();
        } else {
          stream.sendHeaders([
            Header.ascii(':status', '200'),
            Header.ascii('x-late-state', 'shared-dynamic-value')
          ], endStream: true);
        }
      }, onError: (Object error) {
        if (!closing) fail('unexpected h2 connection error: $error');
      });
    });
    final transport = Http2Client(
        context: SecurityContext()
          ..setTrustedCertificates('test/fixtures/http2-local-cert.pem'));
    final url = Uri.parse('https://localhost:${server.port}');
    final client = E2BClient(
        apiKey: 'management-key',
        apiUrl: url,
        sandboxUrl: url,
        retries: 0,
        httpClient: transport);
    addTearDown(() async {
      closing = true;
      client.close();
      transport.close();
      for (final connection in connections) {
        await connection.terminate();
      }
      await server.close();
    });
    final sandbox = await client.connect('sb');
    final signal = CancellationSignal();
    final reason = StateError('cancel h2 health');
    final checked = expectLater(
        sandbox.isRunning(options: RequestOptions(signal: signal)),
        throwsA(same(reason)));
    await ready.future.timeout(const Duration(seconds: 3));
    signal.cancel(reason);
    await checked.timeout(const Duration(seconds: 3));
    await reset.future.timeout(const Duration(seconds: 3));
    expect(healthRequests, 1);
    expect(await sandbox.isRunning(), isTrue);
    final response = await transport
        .get(url.resolve('/health'), headers: {'x-access-token': 'envd-token'});
    expect(response.headers['x-late-state'], 'shared-dynamic-value');
    expect(ids, [1, 3, 5, 7]);
    expect(connections, hasLength(1));
  });
}
