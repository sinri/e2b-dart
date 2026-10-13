import 'dart:convert';

/// Node Buffer.toString('utf8') replaces invalid bytes and preserves a BOM.
String nodeUtf8Decode(List<int> bytes) {
  final bom = bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf;
  return '${bom ? '\uFEFF' : ''}${utf8.decode(bytes, allowMalformed: true)}';
}
