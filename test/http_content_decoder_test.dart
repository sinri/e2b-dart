import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:e2b/src/http_client_io.dart';
import 'package:http/http.dart' as http;
import 'package:e2b/src/http_content_decoder_io.dart';
import 'package:test/test.dart';

void main() {
  test('compression truncation and corruption match Node fetch vectors',
      () async {
    final vectors = (jsonDecode(
            File('test/http_compression_edges_vectors.json').readAsStringSync())
        as Map)['vectors'] as List;
    final differences = <String>[];
    for (final item in vectors.cast<Map>()) {
      for (final fragmented in [false, true]) {
        final input = base64Decode(item['input'] as String);
        List<int>? output;
        Object? failure;
        try {
          output = await decodeHttpContent(
                  fragmented
                      ? Stream.fromIterable(input.map((byte) => [byte]))
                      : Stream.value(input),
                  {'content-encoding': item['encoding'] as String},
                  'GET',
                  200)
              .expand((bytes) => bytes)
              .toList();
        } catch (error) {
          failure = error;
        }
        if (item.containsKey('error')
            ? failure == null
            : failure != null || base64Encode(output!) != item['output']) {
          differences.add(
              '${item['encoding']} ${item['label']} fragmented=$fragmented: $failure');
        }
      }
    }
    expect(differences, isEmpty);
  });
  for (final version in ['1.1', '2']) {
    for (final partialHeader in [false, true]) {
      test(
          'HTTP $version deflate cancel releases socket partial=$partialHeader',
          () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final eof = Completer<void>();
        final peers = <Socket>[];
        server.listen((socket) {
          peers.add(socket);
          var request = '';
          var replied = false;
          socket.listen((bytes) {
            request += latin1.decode(bytes);
            if (replied || !request.contains('\r\n\r\n')) return;
            replied = true;
            socket.write(
                'HTTP/1.1 200 OK\r\nContent-Encoding: deflate\r\nTransfer-Encoding: chunked\r\n\r\n');
            if (partialHeader) socket.add([49, 13, 10, 0x78, 13, 10]);
          }, onDone: () {
            if (!eof.isCompleted) eof.complete();
          });
        });
        final client = createHttpClient(null, httpVersion: version);
        addTearDown(() async {
          client.close();
          for (final socket in peers) {
            socket.destroy();
          }
          await server.close();
        });
        final response = await client.send(
            http.Request('GET', Uri.parse('http://localhost:${server.port}/')));
        final subscription = response.stream.listen((_) {});
        await Future<void>.delayed(Duration.zero);
        await subscription.cancel().timeout(const Duration(seconds: 3));
        // Observed before client.close; cancellation must release the response.
        await eof.future.timeout(const Duration(seconds: 3));
      });
    }
  }
  test('deflate cancels upstream after an incomplete header', () async {
    final canceled = Completer<void>();
    final source = StreamController<List<int>>(onCancel: canceled.complete);
    final subscription = decodeHttpContent(
            source.stream, {'content-encoding': 'deflate'}, 'GET', 200)
        .listen((_) {});
    addTearDown(() async {
      unawaited(source.close());
      await subscription.cancel();
    });
    source.add([0x78]);
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel().timeout(const Duration(seconds: 1));
    await canceled.future.timeout(const Duration(seconds: 1));
  });
  for (final encoding in ['gzip', 'deflate', 'gzip, deflate']) {
    test('$encoding cancels upstream while waiting for first bytes', () async {
      final listening = Completer<void>();
      final canceled = Completer<void>();
      final source = StreamController<List<int>>(
          onListen: listening.complete, onCancel: canceled.complete);
      final decoded = decodeHttpContent(
          source.stream, {'content-encoding': encoding}, 'GET', 200);
      final subscription = decoded.listen((_) {});
      addTearDown(() async {
        source.add([]);
        unawaited(source.close());
        await subscription.cancel();
      });
      await listening.future;
      await subscription.cancel().timeout(const Duration(seconds: 1));
      await canceled.future.timeout(const Duration(seconds: 1));
    });
  }
}
