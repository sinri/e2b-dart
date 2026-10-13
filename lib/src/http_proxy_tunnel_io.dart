import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'proxy_config.dart';

/// Establish an HTTP CONNECT tunnel, retaining the raw subscription for TLS.
Future<StreamSubscription<RawSocketEvent>> openHttpTunnel(
    RawSocket socket, Uri target, Uri proxy) async {
  final host = target.host.contains(':') ? '[${target.host}]' : target.host;
  final authority = '$host:${target.port}';
  final credentials = proxyCredentials(proxy);
  final authorization = proxy.userInfo.isEmpty
      ? ''
      : 'Proxy-Authorization: Basic ${base64Encode(utf8.encode('${credentials.$1}:${credentials.$2}'))}\r\n';
  final request = utf8.encode(
      'CONNECT $authority HTTP/1.1\r\nHost: $authority\r\n$authorization\r\n');
  var offset = 0;
  final header = <int>[];
  final response = Completer<void>();
  void fail(Object error) {
    if (!response.isCompleted) response.completeError(error);
  }

  void write() {
    while (offset < request.length) {
      final written = socket.write(request, offset);
      if (written == 0) {
        socket.writeEventsEnabled = true;
        return;
      }
      offset += written;
    }
    socket.writeEventsEnabled = false;
  }

  final subscription = socket.listen((event) {
    if (response.isCompleted) return;
    if (event == RawSocketEvent.write) write();
    if (event == RawSocketEvent.read) {
      final bytes = socket.read();
      if (bytes == null) return;
      header.addAll(bytes);
      final text = latin1.decode(header);
      final end = text.indexOf('\r\n\r\n');
      if ((end < 0 && header.length > 65536) || end > 65532) {
        fail(const SocketException('Proxy CONNECT headers exceed 64 KiB'));
      } else if (end >= 0) {
        final match =
            RegExp(r'^HTTP/1\.[01] ([0-9]{3})(?: |\r)').firstMatch(text);
        if (match == null || match.group(1) != '200') {
          fail(SocketException(
              'Proxy CONNECT failed: ${text.split('\r\n').first}'));
        } else if (end + 4 != header.length) {
          fail(const SocketException(
              'Unexpected data after proxy CONNECT headers'));
        } else {
          socket.readEventsEnabled = false;
          socket.writeEventsEnabled = false;
          response.complete();
        }
      }
    }
    if (event == RawSocketEvent.readClosed || event == RawSocketEvent.closed) {
      fail(const SocketException('Proxy closed during CONNECT'));
    }
  },
      onError: (Object error) => fail(error),
      onDone: () => fail(const SocketException('Proxy closed during CONNECT')));
  try {
    write();
    await response.future;
    return subscription;
  } catch (_) {
    await socket.close();
    await subscription.cancel();
    rethrow;
  }
}
