/// ECMAScript WhiteSpace and LineTerminator code points used by String.trim.
final _jsTrimStart = RegExp(
    r'^[\u0009-\u000D\u0020\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]+');
final _jsTrimEnd = RegExp(
    r'[\u0009-\u000D\u0020\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]+$');

String jsTrim(String value) =>
    value.replaceFirst(_jsTrimStart, '').replaceFirst(_jsTrimEnd, '');
