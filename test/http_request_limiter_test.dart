import 'dart:async';
import 'package:e2b/src/http_request_limiter.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  http.Request request() =>
      http.Request('GET', Uri.parse('https://test.invalid'));
  Future<void> tick() => Future<void>.delayed(Duration.zero);

  test('FIFO slots release at headers even with an unconsumed body', () async {
    final limiter = HttpRequestLimiter(1);
    final headers = Completer<http.StreamedResponse>();
    final body = StreamController<List<int>>();
    final order = <int>[];
    final first = limiter.run(request(), () {
      order.add(1);
      return headers.future;
    });
    final second = limiter.run(request(), () async {
      order.add(2);
      return 2;
    });
    final third = limiter.run(request(), () async {
      order.add(3);
      return 3;
    });
    await tick();
    expect(order, [1]);
    headers.complete(http.StreamedResponse(body.stream, 200));
    await first;
    expect(await second, 2);
    expect(await third, 3);
    expect(order, [1, 2, 3]);
    final drained = body.stream.drain<void>();
    await body.close();
    await drained;
  });

  test('queued abort removes only its waiter and failure releases the slot',
      () async {
    final limiter = HttpRequestLimiter(1);
    final held = Completer<void>();
    final first = limiter.run(request(), () => held.future);
    final abort = Completer<void>();
    var dispatched = false;
    final canceled = limiter.run(
        http.AbortableRequest('GET', request().url, abortTrigger: abort.future),
        () async {
      dispatched = true;
    });
    final checked =
        expectLater(canceled, throwsA(isA<http.RequestAbortedException>()));
    final last = limiter.run(request(), () async => 3);
    await tick();
    abort.complete();
    await checked;
    expect(dispatched, isFalse);
    final failed = expectLater(first, throwsStateError);
    held.completeError(StateError('failure'));
    await failed;
    expect(await last, 3);
  });

  test('pre-abort, close and disabled cap preserve dispatch boundaries',
      () async {
    final limiter = HttpRequestLimiter(0);
    final aborted = Completer<void>()..complete();
    var calls = 0;
    await expectLater(
        limiter.run(
            http.AbortableRequest('GET', request().url,
                abortTrigger: aborted.future), () async {
          calls++;
        }),
        throwsA(isA<http.RequestAbortedException>()));
    expect(calls, 0);
    final held = Completer<void>();
    final first = limiter.run(request(), () => held.future);
    expect(await limiter.run(request(), () async => 2), 2);
    limiter.close();
    await expectLater(limiter.run(request(), () async => 3),
        throwsA(isA<http.ClientException>()));
    held.complete();
    await first;
    final capped = HttpRequestLimiter(1);
    final gate = Completer<void>();
    final active = capped.run(request(), () => gate.future);
    final queued = capped.run(request(), () async => 4);
    final checked = expectLater(queued, throwsA(isA<http.ClientException>()));
    await tick();
    capped.close();
    await checked;
    gate.complete();
    await active;
  });
}
