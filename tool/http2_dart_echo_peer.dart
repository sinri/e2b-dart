// Diagnostic Dart HTTP/2 peer for the large-payload interoperability test.
import 'dart:io';
import 'dart:typed_data';
import 'package:http2/transport.dart';

Future<void> main() async {
  final context = SecurityContext()
    ..useCertificateChain('test/fixtures/http2-local-cert.pem')
    ..usePrivateKey('test/fixtures/http2-local-key.pem')
    ..setAlpnProtocols(['h2'], true);
  final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4, 0, context,
      supportedProtocols: ['h2']);
  server.listen((socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    final transport = ServerTransportConnection.viaSocket(socket);
    transport.incomingStreams.listen((stream) async {
      final messages = await stream.incomingMessages.toList();
      final bytes = BytesBuilder(copy: false);
      for (final message in messages.whereType<DataStreamMessage>()) {
        bytes.add(message.bytes);
      }
      final body = bytes.takeBytes();
      stream.sendHeaders([
        Header.ascii(':status', '200'),
        Header.ascii('content-length', '${body.length}')
      ]);
      for (var offset = 0; offset < body.length; offset += 4091) {
        final end = offset + 4091 < body.length ? offset + 4091 : body.length;
        stream.sendData(body.sublist(offset, end),
            endStream: end == body.length);
      }
    });
  });
  stdout.writeln(server.port);
}
