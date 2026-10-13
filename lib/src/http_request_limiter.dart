import 'dart:async';
import 'dart:collection';
import 'package:http/http.dart' as http;

/// FIFO dispatch slots, released at response headers like the JS fetch wrapper.
class HttpRequestLimiter {
  final num max;
  int _active = 0;
  bool _closed = false;
  final Queue<_Waiter> _queue = Queue();
  HttpRequestLimiter(this.max);

  Future<T> run<T>(http.BaseRequest request, Future<T> Function() send) async {
    final waiter = _Waiter(request);
    unawaited(waiter.ready.future.then<void>((_) {}, onError: (Object _) {}));
    if (request is http.Abortable && request.abortTrigger != null) {
      unawaited(request.abortTrigger!.then((_) {
        if (!waiter.granted && !waiter.ready.isCompleted) {
          _queue.remove(waiter);
          waiter.ready.completeError(http.RequestAbortedException(request.url));
        }
      }));
    }
    // Let an already completed abort signal win before reserving a slot.
    await Future<void>.value();
    if (waiter.ready.isCompleted) await waiter.ready.future;
    if (_closed) throw http.ClientException('Client is closed', request.url);
    if (max <= 0 || _active < max) {
      _grant(waiter);
    } else {
      _queue.add(waiter);
    }
    await waiter.ready.future;
    try {
      return await send();
    } finally {
      _active--;
      if (_queue.isNotEmpty) _grant(_queue.removeFirst());
    }
  }

  void _grant(_Waiter waiter) {
    waiter.granted = true;
    _active++;
    waiter.ready.complete();
  }

  void close() {
    _closed = true;
    while (_queue.isNotEmpty) {
      final waiter = _queue.removeFirst();
      waiter.ready.completeError(
          http.ClientException('Client is closed', waiter.request.url));
    }
  }
}

class _Waiter {
  final http.BaseRequest request;
  final Completer<void> ready = Completer<void>();
  bool granted = false;
  _Waiter(this.request);
}
