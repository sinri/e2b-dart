import 'package:e2b/src/http2_frame_observer.dart';
import 'package:test/test.dart';

void main() {
  test('GOAWAY observation handles arbitrary framing without reading payload',
      () {
    final goaway = [0, 0, 8, 7, 0, 0, 0, 0, 0, ...List.filled(8, 0)];
    final data = [0, 0, goaway.length, 0, 0, 0, 0, 0, 1, ...goaway];
    final bytes = [...data, ...goaway, 0, 0, 0, 4, 1, 0, 0, 0, 0, ...goaway];
    for (var chunkSize = 1; chunkSize <= bytes.length; chunkSize++) {
      var count = 0;
      final observer = Http2FrameObserver(() => count++);
      for (var offset = 0; offset < bytes.length; offset += chunkSize) {
        observer.add(bytes.sublist(
            offset,
            offset + chunkSize > bytes.length
                ? bytes.length
                : offset + chunkSize));
      }
      expect(count, 2, reason: 'chunkSize=$chunkSize');
    }
    var count = 0;
    Http2FrameObserver(() => count++).add([0, 0, 0, 7, 0, 0, 0, 0, 1]);
    expect(count, 0, reason: 'nonzero stream is left to transport validation');
  });
}
