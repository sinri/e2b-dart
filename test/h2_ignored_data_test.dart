import 'dart:async';
import 'package:e2b/src/vendor/http2/src/flowcontrol/connection_queues.dart';
import 'package:e2b/src/vendor/http2/src/flowcontrol/window.dart';
import 'package:e2b/src/vendor/http2/src/flowcontrol/queue_messages.dart';
import 'package:e2b/src/vendor/http2/src/flowcontrol/stream_queues.dart';
import 'package:e2b/src/vendor/http2/src/flowcontrol/window_handler.dart';
import 'package:e2b/src/vendor/http2/src/frames/frames.dart';
import 'package:e2b/src/vendor/http2/src/hpack/hpack.dart';
import 'package:e2b/src/vendor/http2/src/settings/settings.dart';
import 'package:test/test.dart';

void main() {
  test('empty ignored DATA emits no zero WINDOW_UPDATE', () async {
    final output = StreamController<List<int>>();
    final bytes = <int>[];
    final drained = output.stream.forEach(bytes.addAll);
    final writer =
        FrameWriter(HPackContext().encoder, output.sink, ActiveSettings());
    final window = Window();
    final queue = ConnectionMessageQueueIn(
        IncomingWindowHandler.connection(writer, window), (action) => action());
    queue.processIgnoredDataFrame(DataFrame(FrameHeader(0, 0, 0, 1), 0, []));
    expect(window.size, 65535);
    await writer.close();
    await drained;
    expect(bytes, isEmpty);
  });

  test('stream padding is returned before payload consumption', () async {
    final output = StreamController<List<int>>();
    final drained = output.stream.drain<void>();
    final writer =
        FrameWriter(HPackContext().encoder, output.sink, ActiveSettings());
    final window = Window();
    final queue =
        StreamMessageQueueIn(IncomingWindowHandler.stream(writer, window, 1));
    queue.enqueueMessage(
        DataMessage(1, [1, 2, 3], true, flowControlLength: 259));
    expect(window.size, 65532);
    await queue.messages.toList();
    expect(window.size, 65535);
    await writer.close();
    await drained;
  });

  test('ignored DATA restores only the connection credit it consumed',
      () async {
    final output = StreamController<List<int>>();
    final bytes = <int>[];
    final drained = output.stream.forEach(bytes.addAll);
    final writer =
        FrameWriter(HPackContext().encoder, output.sink, ActiveSettings());
    final window = Window();
    final queue = ConnectionMessageQueueIn(
        IncomingWindowHandler.connection(writer, window), (action) => action());
    for (final size in [1, 16000, 16000, 16000, 16000]) {
      queue.processIgnoredDataFrame(
          DataFrame(FrameHeader(size, 0, 0, 1), 0, List.filled(size, 120)));
      expect(window.size, 65535,
          reason: 'closed DATA must not inflate advertised credit');
    }
    await writer.close();
    await drained;
    var credited = 0;
    for (var offset = 0; offset < bytes.length;) {
      final length =
          bytes[offset] << 16 | bytes[offset + 1] << 8 | bytes[offset + 2];
      expect(bytes[offset + 3], 8); // WINDOW_UPDATE.
      expect(bytes.sublist(offset + 5, offset + 9), [0, 0, 0, 0]);
      credited += (bytes[offset + 9] & 127) << 24 |
          bytes[offset + 10] << 16 |
          bytes[offset + 11] << 8 |
          bytes[offset + 12];
      offset += 9 + length;
    }
    expect(credited, 64001);
  });
}
