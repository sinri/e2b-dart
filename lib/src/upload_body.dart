import 'dart:async';
import 'dart:convert';
import 'connection.dart';

class UploadBody {
  final Object data;
  final bool streamed;
  const UploadBody(this.data, this.streamed);
}

Stream<List<int>> uploadBytes(Object data) => switch (data) {
      Stream<List<int>> stream => stream,
      String text => Stream.value(utf8.encode(text)),
      List<int> bytes => Stream.value(bytes),
      _ =>
        throw ArgumentError('File data must be text, bytes, or a byte stream'),
    };

/// Collect browser/multipart input while honoring cancellation before HTTP send.
Future<List<int>> collectUploadBytes(Object data,
    {CancellationSignal? signal}) async {
  signal?.throwIfCanceled();
  final result = Completer<List<int>>();
  final bytes = <int>[];
  final subscription = uploadBytes(data).listen(bytes.addAll,
      onError: (Object error, StackTrace stack) {
    if (!result.isCompleted) result.completeError(error, stack);
  }, onDone: () {
    if (!result.isCompleted) result.complete(bytes);
  }, cancelOnError: true);
  final remove = signal?.listen(() {
    if (!result.isCompleted) result.completeError(signal.reason);
  });
  try {
    return await result.future;
  } finally {
    remove?.call();
    await subscription.cancel();
  }
}
