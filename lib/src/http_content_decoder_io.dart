import 'dart:async';
import 'dart:convert';
import 'dart:io';

Stream<List<int>> decodeHttpContent(Stream<List<int>> source,
    Map<String, String> headers, String method, int status) {
  final encodings = (headers['content-encoding'] ?? '')
      .split(',')
      .map((value) => value.trim().toLowerCase())
      .toList();
  if (method == 'HEAD' ||
      status == 204 ||
      status == 304 ||
      !encodings.every(
          (value) => const {'gzip', 'x-gzip', 'deflate'}.contains(value))) {
    return source;
  }
  var result = source;
  for (final encoding in encodings.reversed) {
    result = encoding == 'deflate'
        ? _decodeDeflate(result)
        : result.transform(gzip.decoder);
  }
  return result;
}

// Fetch accepts both zlib-wrapped and raw deflate. Select from the first byte
// without buffering the complete response or losing cancellation propagation.
Stream<List<int>> _decodeDeflate(Stream<List<int>> source) =>
    Stream.eventTransformed(source, _DeflateSink.new);

class _DeflateSink implements EventSink<List<int>> {
  final EventSink<List<int>> output;
  ByteConversionSink? decoder;
  _DeflateSink(this.output);
  @override
  void add(List<int> bytes) {
    if (bytes.isEmpty) return;
    try {
      decoder ??= ZLibDecoder(raw: bytes.first & 0x0f != 8)
          .startChunkedConversion(output);
      decoder!.add(bytes);
    } catch (error, stack) {
      output.addError(error, stack);
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      output.addError(error, stackTrace);
  @override
  void close() {
    try {
      if (decoder == null) {
        output.close();
      } else {
        decoder!.close();
      }
    } catch (error, stack) {
      output.addError(error, stack);
      output.close();
    }
  }
}
