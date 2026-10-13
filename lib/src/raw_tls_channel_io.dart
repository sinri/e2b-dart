import 'dart:async';
import 'dart:io';

/// Byte streams over a raw TLS socket, retaining the close handle during the
/// handshake in the owning pool. Writes wait for writable events when needed.
class RawTlsChannel {
  final RawSecureSocket socket;
  late final StreamController<List<int>> _input;
  late final _RawTlsConsumer _consumer;
  late final IOSink output;
  late final StreamSubscription<RawSocketEvent> _events;
  final Completer<void> _done = Completer<void>();
  bool _closed = false;
  Future<void> get done => _done.future;
  void _finish() {
    if (!_done.isCompleted) _done.complete();
  }

  Stream<List<int>> get input => _input.stream;

  RawTlsChannel(this.socket) {
    _consumer = _RawTlsConsumer(socket);
    output = IOSink(_consumer);
    // Observe sink errors even when a transport closes without awaiting done.
    unawaited(
        output.done.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    _input = StreamController<List<int>>(
      onPause: () => socket.readEventsEnabled = false,
      onResume: () => socket.readEventsEnabled = true,
      onCancel: close,
    );
    _events = socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final bytes = socket.read();
        if (bytes != null && !_input.isClosed) _input.add(bytes);
      } else if (event == RawSocketEvent.write) {
        socket.writeEventsEnabled = false;
        _consumer.writable();
      } else if (event == RawSocketEvent.readClosed) {
        _finish();
        unawaited(_input.close());
      } else if (event == RawSocketEvent.closed) {
        _finish();
        _consumer.fail(const SocketException('TLS socket closed'));
        unawaited(_input.close());
      }
    }, onError: (Object error, StackTrace stack) {
      _consumer.fail(error);
      _finish();
      if (!_input.isClosed) _input.addError(error, stack);
      unawaited(_input.close());
    }, onDone: () {
      _finish();
      unawaited(_input.close());
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _consumer.fail(const SocketException('TLS socket closed'));
    await socket.close();
    await _events.cancel();
    _finish();
  }
}

class _RawTlsConsumer implements StreamConsumer<List<int>> {
  final RawSecureSocket socket;
  Completer<void>? _writable;
  Object? _failure;
  _RawTlsConsumer(this.socket);
  void writable() {
    final waiting = _writable;
    _writable = null;
    waiting?.complete();
  }

  void fail(Object error) {
    _failure ??= error;
    final waiting = _writable;
    _writable = null;
    waiting?.completeError(error);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final bytes in stream) {
      var offset = 0;
      while (offset < bytes.length) {
        if (_failure != null) throw _failure!;
        final count = socket.write(bytes, offset);
        if (count == 0) {
          final waiting = _writable = Completer<void>();
          socket.writeEventsEnabled = true;
          await waiting.future;
        } else {
          offset += count;
        }
      }
    }
  }

  @override
  Future<void> close() async {
    socket.shutdown(SocketDirection.send);
  }
}
