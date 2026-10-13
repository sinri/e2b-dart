/// Format a binary64 number using JavaScript's decimal/exponent thresholds.
String jsNumberString(num value) {
  final number = value.toDouble();
  if (number == 0) return '0';
  if (!number.isFinite) return number.toString();
  final sign = number < 0 ? '-' : '';
  final parts = number.abs().toString().toLowerCase().split('e');
  final mantissa = parts.first;
  final dot = mantissa.indexOf('.');
  final decimal = dot < 0 ? mantissa.length : dot;
  var digits = mantissa.replaceAll('.', '');
  var position = decimal + (parts.length == 2 ? int.parse(parts[1]) : 0);
  while (digits.startsWith('0') && digits.length > 1) {
    digits = digits.substring(1);
    position--;
  }
  while (digits.endsWith('0') && digits.length > 1) {
    digits = digits.substring(0, digits.length - 1);
  }
  if (position > 0 && position <= 21) {
    return sign +
        (position >= digits.length
            ? digits + '0' * (position - digits.length)
            : '${digits.substring(0, position)}.${digits.substring(position)}');
  }
  if (position <= 0 && position > -6) {
    return '${sign}0.${'0' * -position}$digits';
  }
  final exponent = position - 1;
  final fraction = digits.length == 1 ? '' : '.${digits.substring(1)}';
  return '$sign${digits[0]}${fraction}e${exponent >= 0 ? '+' : ''}$exponent';
}
