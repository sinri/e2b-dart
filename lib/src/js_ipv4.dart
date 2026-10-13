/// WHATWG IPv4-number parsing for special URL hosts. Non-numeric hosts pass on.
String jsIpv4Host(String host) {
  final parts = host.split('.');
  if (parts.last.isEmpty && parts.length > 1) parts.removeLast();
  BigInt? number(String value) {
    if (value.isEmpty) return null;
    var radix = 10;
    if (value.length >= 2 && value.substring(0, 2).toLowerCase() == '0x') {
      radix = 16;
      value = value.substring(2);
    } else if (value.length >= 2 && value.startsWith('0')) {
      radix = 8;
      value = value.substring(1);
    }
    if (value.isEmpty) return BigInt.zero;
    final pattern = radix == 16
        ? r'^[0-9a-fA-F]+$'
        : radix == 8
            ? r'^[0-7]+$'
            : r'^[0-9]+$';
    return RegExp(pattern).hasMatch(value)
        ? BigInt.tryParse(value, radix: radix)
        : null;
  }

  if (!RegExp(r'^[0-9]+$').hasMatch(parts.last) && number(parts.last) == null) {
    return host;
  }
  if (parts.length > 4) throw const FormatException('Invalid IPv4 host');
  final values = parts.map(number).toList();
  if (values.any((v) => v == null) ||
      values.take(values.length - 1).any((v) => v! > BigInt.from(255)) ||
      values.last! >= (BigInt.one << (8 * (5 - values.length)))) {
    throw const FormatException('Invalid IPv4 host');
  }
  var address = values.last!;
  for (var i = 0; i < values.length - 1; i++) {
    address += values[i]! << (8 * (3 - i));
  }
  return List.generate(
          4, (i) => ((address >> (8 * (3 - i))) & BigInt.from(255)).toString())
      .join('.');
}
