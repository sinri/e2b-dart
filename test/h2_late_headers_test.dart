import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:e2b/src/http2_client_io.dart';
import 'package:e2b/src/vendor/http2/transport.dart'
    show TransportConnectionException;
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

List<int> frame(int type, int flags, int stream, List<int> payload) => [
      payload.length >> 16,
      (payload.length >> 8) & 255,
      payload.length & 255,
      type,
      flags,
      (stream >> 24) & 127,
      (stream >> 16) & 255,
      (stream >> 8) & 255,
      stream & 255,
      ...payload,
    ];

void main() {
  for (final scenario in ['headers', 'data', 'padded', 'empty', 'idle']) {
    final idle = scenario == 'idle';
    final lateData = scenario == 'data' || scenario == 'padded';
    final padded = scenario == 'padded';
    final expectedCredit = padded ? 65024 : 64000;
    test('raw h2 canceled/idle stream scenario=$scenario', () async {
      final context = SecurityContext()
        ..useCertificateChain('test/fixtures/http2-local-cert.pem')
        ..usePrivateKey('test/fixtures/http2-local-key.pem')
        ..setAlpnProtocols(['h2'], true);
      final server = await SecureServerSocket.bind(
          InternetAddress.loopbackIPv4, 0, context,
          supportedProtocols: ['h2']);
      final sockets = <SecureSocket>[];
      final first = Completer<void>();
      final lateSent = Completer<void>();
      final ids = <int>[];
      final creditReturned = Completer<void>();
      var credit = 0;
      var sentLate = false;
      server.listen((socket) {
        sockets.add(socket);
        expect(socket.selectedProtocol, 'h2');
        socket.add(frame(4, 0, 0, [])); // Initial SETTINGS.
        final buffer = <int>[];
        var preface = false;
        socket.listen((bytes) {
          buffer.addAll(bytes);
          if (!preface) {
            if (buffer.length < 24) return;
            expect(ascii.decode(buffer.sublist(0, 24)),
                'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n');
            buffer.removeRange(0, 24);
            preface = true;
          }
          while (buffer.length >= 9) {
            final length = buffer[0] << 16 | buffer[1] << 8 | buffer[2];
            if (buffer.length < 9 + length) return;
            final type = buffer[3];
            final flags = buffer[4];
            final stream = (buffer[5] & 127) << 24 |
                buffer[6] << 16 |
                buffer[7] << 8 |
                buffer[8];
            final payload = buffer.sublist(9, 9 + length);
            buffer.removeRange(0, 9 + length);
            if (type == 8) {
              final increment = (payload[0] & 127) << 24 |
                  payload[1] << 16 |
                  payload[2] << 8 |
                  payload[3];
              expect(increment, greaterThan(0),
                  reason: 'WINDOW_UPDATE delta must not be zero');
            }
            if (type == 8 && stream == 0 && lateData) {
              credit += (payload[0] & 127) << 24 |
                  payload[1] << 16 |
                  payload[2] << 8 |
                  payload[3];
              if (credit >= expectedCredit && !creditReturned.isCompleted) {
                creditReturned.complete();
              }
            }
            if (type == 4 && flags & 1 == 0) socket.add(frame(4, 1, 0, []));
            if (type == 1) {
              ids.add(stream);
              if (stream == 1) {
                if (idle) {
                  // A server cannot open idle client stream 3.
                  socket.add(frame(1, 5, 3, [0x88]));
                }
                first.complete();
              } else {
                // Index 62 must reference the entry decoded on canceled stream 1.
                socket.add(frame(1, padded ? 4 : 5, stream, [0x88, 0xbe]));
                if (padded) {
                  socket.add(frame(0, 9, stream,
                      [255, ...ascii.encode('ok'), ...List.filled(255, 0)]));
                }
              }
            }
            if (!idle && type == 3 && stream == 1 && !sentLate) {
              sentLate = true;
              final name = ascii.encode('x-late-state');
              final value = ascii.encode('dynamic-value');
              final block = [
                0x88,
                0x40,
                name.length,
                ...name,
                value.length,
                ...value
              ];
              // END_STREAM on HEADERS, END_HEADERS only on CONTINUATION.
              socket.add(frame(1, 1, 1, block.sublist(0, 6)));
              socket.add(frame(9, 4, 1, block.sublist(6)));
              if (scenario == 'empty') socket.add(frame(0, 0, 1, []));
              if (lateData) {
                for (var i = 0; i < 4; i++) {
                  socket.add(frame(0, padded ? 8 : 0, 1, [
                    if (padded) 255,
                    ...List.filled(16000, 120),
                    if (padded) ...List.filled(255, 0),
                  ]));
                }
              }
              unawaited(socket.flush().then((_) => lateSent.complete()));
            }
          }
        }, onError: (Object _) {});
      });
      final client = Http2Client(
          context: SecurityContext()
            ..setTrustedCertificates('test/fixtures/http2-local-cert.pem'));
      addTearDown(() async {
        client.close();
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
      });
      final url = Uri.parse('https://localhost:${server.port}/');
      final abort = Completer<void>();
      final pending = client
          .send(http.AbortableRequest('GET', url, abortTrigger: abort.future));
      final checked = expectLater(
          pending,
          throwsA(idle
              ? isA<TransportConnectionException>()
                  .having((error) => error.errorCode, 'protocol error code', 1)
              : isA<http.RequestAbortedException>()));
      await first.future.timeout(const Duration(seconds: 3));
      if (!idle) {
        abort.complete();
        await checked.timeout(const Duration(seconds: 3));
        await lateSent.future.timeout(const Duration(seconds: 3));
        if (lateData) {
          await creditReturned.future.timeout(const Duration(seconds: 3));
          expect(credit, expectedCredit);
        }
        final response =
            await client.get(url).timeout(const Duration(seconds: 3));
        expect(response.statusCode, 200);
        expect(response.headers['x-late-state'], 'dynamic-value');
        if (padded) expect(response.body, 'ok');
        expect(ids, [1, 3]);
        expect(sockets, hasLength(1));
      } else {
        await checked.timeout(const Duration(seconds: 3));
      }
    });
  }
}
