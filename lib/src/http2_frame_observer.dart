/// Observes frame boundaries without buffering payloads or decoding HPACK.
/// Protocol validation remains the responsibility of the HTTP/2 transport.
class Http2FrameObserver {
  final void Function() onGoaway;
  final List<int> _header = [];
  int _remaining = 0;
  Http2FrameObserver(this.onGoaway);

  void add(List<int> bytes) {
    var offset = 0;
    while (offset < bytes.length) {
      if (_remaining > 0) {
        final count = bytes.length - offset;
        final skip = count < _remaining ? count : _remaining;
        _remaining -= skip;
        offset += skip;
        continue;
      }
      _header.add(bytes[offset++]);
      if (_header.length != 9) continue;
      _remaining = (_header[0] << 16) | (_header[1] << 8) | _header[2];
      final stream = ((_header[5] & 0x7f) << 24) |
          (_header[6] << 16) |
          (_header[7] << 8) |
          _header[8];
      if (_header[3] == 7 && stream == 0) onGoaway();
      _header.clear();
    }
  }
}
