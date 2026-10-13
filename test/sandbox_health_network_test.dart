import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:e2b/e2b.dart';
import 'package:e2b/src/http2_client_io.dart';
import 'package:http2/transport.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  test('real h2 health cancellation resets only its stream', () async {
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
          stream.sendHeaders([Header.ascii(':status', '200')]);
          stream.sendData([120]);
          ready.complete();
        } else {
          stream.sendHeaders([Header.ascii(':status', '200')], endStream: true);
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
    final received = Completer<void>();
    final checked = expectLater(
        sandbox.isRunning(
            options: RequestOptions(
                signal: signal,
                logger: Logger(info: (args) {
                  if (args.first == 'Response:' && !received.isCompleted) {
                    received.complete();
                  }
                }))),
        throwsA(same(reason)));
    await ready.future.timeout(const Duration(seconds: 3));
    await received.future.timeout(const Duration(seconds: 3));
    signal.cancel(reason);
    await checked.timeout(const Duration(seconds: 3));
    await reset.future.timeout(const Duration(seconds: 3));
    expect(healthRequests, 1);
    expect(await sandbox.isRunning(), isTrue);
    expect(ids, [1, 3, 5]);
    expect(connections, hasLength(1));
  });

  for (final version in ['1.1', '2']) {
    test('health body cancellation releases socket over HTTP $version',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final ready = Completer<void>();
      final eof = Completer<void>();
      Socket? stalled;
      addTearDown(() => stalled?.destroy());
      var healthRequests = 0;
      server.listen((request) async {
        await request.drain<void>();
        if (request.uri.path.endsWith('/connect')) {
          request.response.headers.contentType = ContentType.json;
          request.response
              .write(jsonEncode({'sandboxID': 'sb', 'envdVersion': '0.6.4'}));
          await request.response.close();
          return;
        }
        expect(request.uri.path, '/health');
        healthRequests++;
        if (healthRequests == 1) {
          final socket =
              await request.response.detachSocket(writeHeaders: false);
          stalled = socket;
          socket.listen((_) {}, onError: (Object error) {
            expect(error, isA<SocketException>());
            if (!eof.isCompleted) eof.complete();
          }, onDone: () {
            if (!eof.isCompleted) eof.complete();
          });
          socket.write(
              'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx\r\n');
          await socket.flush();
          ready.complete();
        } else {
          await request.response.close();
        }
      });
      final url = Uri.parse('http://localhost:${server.port}');
      final client = E2BClient(
          apiKey: 'key',
          apiUrl: url,
          sandboxUrl: url,
          httpVersion: version,
          retries: 0);
      addTearDown(client.close);
      final sandbox = await client.connect('sb');
      final signal = CancellationSignal();
      final reason = StateError('cancel health');
      final pending =
          sandbox.isRunning(options: RequestOptions(signal: signal));
      final check = expectLater(pending, throwsA(same(reason)));
      await ready.future.timeout(const Duration(seconds: 3));
      signal.cancel(reason);
      await check.timeout(const Duration(seconds: 3));
      await eof.future.timeout(const Duration(seconds: 3));
      expect(healthRequests, 1);
      expect(await sandbox.isRunning(), isTrue);
      expect(healthRequests, 2);
    });

    test('health truncated body probes stopped sandbox over HTTP $version',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var healthRequests = 0;
      server.listen((request) async {
        await request.drain<void>();
        if (request.uri.path.endsWith('/connect')) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'sandboxID': 'sb',
            'envdVersion': '0.6.4',
            'envdAccessToken': 'envd-token',
          }));
          await request.response.close();
          return;
        }
        expect(request.uri.path, '/health');
        expect(request.headers.value('x-access-token'), 'envd-token');
        expect(request.headers.value('x-api-key'), isNull);
        healthRequests++;
        if (healthRequests == 1) {
          final socket =
              await request.response.detachSocket(writeHeaders: false);
          socket.write(
              'HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\npartial');
          await socket.flush();
          await socket.close();
        } else {
          request.response.statusCode = 502;
          request.response.headers.contentType = ContentType.json;
          request.response
              .write(jsonEncode({'message': 'sandbox sb was not found'}));
          await request.response.close();
        }
      });
      final url = Uri.parse('http://localhost:${server.port}');
      final client = E2BClient(
          apiKey: 'management-key',
          apiUrl: url,
          sandboxUrl: url,
          httpVersion: version,
          retries: 0);
      addTearDown(client.close);
      final sandbox = await client.connect('sb');
      await expectLater(
          sandbox.isRunning(),
          throwsA(isA<SandboxNotRunningException>().having(
              (error) => error.cause, 'cause', isA<http.ClientException>())));
      expect(healthRequests, 2);
    });
  }
}
