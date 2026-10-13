import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:e2b/src/js_number.dart';
import 'package:test/test.dart';

void main() {
  test('number strings match Node for fixed binary64 bit patterns', () {
    final vectors =
        jsonDecode(File('test/js_number_vectors.json').readAsStringSync())
            as List;
    for (final vector in vectors) {
      final bits = vector['bits'] as String;
      final bytes = Uint8List.fromList([
        for (var offset = 0; offset < bits.length; offset += 2)
          int.parse(bits.substring(offset, offset + 2), radix: 16)
      ]);
      final number = ByteData.sublistView(bytes).getFloat64(0);
      expect(jsNumberString(number), vector['text'], reason: bits);
    }
  });
}
