// Adapted from E2B dockerfile-utils / BuildKit (Apache-2.0).
import 'dart:convert';

bool shellIsSpace(String ch) =>
    RegExp(r'^[\t\n\v\f\r \u0085\u00a0\p{Z}]$', unicode: true).hasMatch(ch);
bool _letter(String ch) => RegExp(r'^\p{L}$', unicode: true).hasMatch(ch);
bool _digit(String ch) => RegExp(r'^\p{Nd}$', unicode: true).hasMatch(ch);

class _Scanner {
  final List<String> chars;
  int pos = 0;
  _Scanner(String text) : chars = text.runes.map(String.fromCharCode).toList();
  String? get peek => pos < chars.length ? chars[pos] : null;
  String? next() => pos < chars.length ? chars[pos++] : null;
}

class _Words {
  final List<String> words = [];
  String buf = '';
  bool inWord = false;
  void addChar(String ch) {
    if (shellIsSpace(ch) && inWord) {
      if (buf.isNotEmpty) {
        words.add(buf);
        buf = '';
        inWord = false;
      }
    } else if (!shellIsSpace(ch)) {
      addRaw(ch);
    }
  }

  void addRaw(String text) {
    buf += text;
    inWord = true;
  }

  void addString(String text) {
    for (final ch in text.runes) {
      addChar(String.fromCharCode(ch));
    }
  }

  List<String> get result {
    if (buf.isNotEmpty) {
      words.add(buf);
      buf = '';
      inWord = false;
    }
    return words;
  }
}

class ShellLex {
  final String escapeToken;
  final bool rawQuotes, rawEscapes, skipProcessQuotes, skipUnsetEnv;
  final Map<String, String> env;
  const ShellLex(this.escapeToken,
      {this.rawQuotes = false,
      this.rawEscapes = false,
      this.skipProcessQuotes = false,
      this.env = const {},
      this.skipUnsetEnv = true});
  String processWord(String word) => _process(word).$1;
  List<String> processWords(String word) => _process(word).$2;
  (String, List<String>) _process(String word) {
    try {
      return _ShellWord(_Scanner(word), this).process(null, rawEscapes);
    } catch (error) {
      throw FormatException(
          'failed to process ${jsonEncode(word)}: ${error is FormatException ? error.message : error}');
    }
  }
}

class _ShellWord {
  final _Scanner scanner;
  final ShellLex lex;
  late bool rawEscapes = lex.rawEscapes;
  _ShellWord(this.scanner, this.lex);
  Never fail(String text) => throw FormatException(text);
  (String, List<String>) process(String? stop, bool raw) {
    var result = '';
    final words = _Words();
    final previous = rawEscapes;
    rawEscapes = raw;
    try {
      while (scanner.peek != null) {
        var ch = scanner.peek!;
        if (stop != null && ch == stop) {
          scanner.next();
          return (result, words.result);
        }
        String? special;
        if (ch == r'$') {
          special = dollar();
        } else if (ch == '<') {
          special = heredoc();
        } else if (!lex.skipProcessQuotes && ch == "'") {
          special = singleQuote();
        } else if (!lex.skipProcessQuotes && ch == '"') {
          special = doubleQuote();
        }
        if (special != null) {
          result += special;
          if (ch == r'$') {
            words.addString(special);
          } else {
            words.addRaw(special);
          }
          continue;
        }
        ch = scanner.next()!;
        if (ch == lex.escapeToken) {
          if (rawEscapes) {
            words.addRaw(ch);
            result += ch;
          }
          final next = scanner.next();
          if (next == null) break;
          ch = next;
          words.addRaw(ch);
        } else {
          words.addChar(ch);
        }
        result += ch;
      }
    } finally {
      rawEscapes = previous;
    }
    if (stop != null) {
      fail('unexpected end of statement while looking for matching $stop');
    }
    return (result, words.result);
  }

  String singleQuote() {
    var result = lex.rawQuotes ? scanner.next()! : '';
    if (!lex.rawQuotes) scanner.next();
    while (true) {
      final ch = scanner.next();
      if (ch == null) {
        fail(
            'unexpected end of statement while looking for matching single-quote');
      }
      if (ch == "'") return lex.rawQuotes ? result + ch : result;
      result += ch;
    }
  }

  String doubleQuote() {
    final open = scanner.next()!;
    var result = lex.rawQuotes ? open : '';
    while (true) {
      final peek = scanner.peek;
      if (peek == null) {
        fail(
            'unexpected end of statement while looking for matching double-quote');
      }
      if (peek == '"') {
        final ch = scanner.next()!;
        return lex.rawQuotes ? result + ch : result;
      }
      if (peek == r'$') {
        result += dollar();
        continue;
      }
      var ch = scanner.next()!;
      if (ch == lex.escapeToken) {
        if (rawEscapes) result += ch;
        final after = scanner.peek;
        if (after == null) continue;
        if (after == '"' || after == r'$' || after == lex.escapeToken) {
          ch = scanner.next()!;
        }
      }
      result += ch;
    }
  }

  String name() {
    var name = '';
    while (true) {
      final ch = scanner.peek;
      if (ch == null) break;
      if (name.isEmpty && _digit(ch)) {
        var digits = '';
        while (scanner.peek != null && _digit(scanner.peek!)) {
          digits += scanner.next()!;
        }
        return digits;
      }
      if (name.isEmpty && r'@*#?-$!0'.contains(ch)) return scanner.next()!;
      if (!_letter(ch) && !_digit(ch) && ch != '_') break;
      name += scanner.next()!;
    }
    return name;
  }

  String dollar() {
    scanner.next();
    if (scanner.peek != '{') {
      final key = name();
      if (key.isEmpty) return r'$';
      final value = lex.env[key];
      return value == null && lex.skipUnsetEnv ? '\$$key' : value ?? '';
    }
    scanner.next();
    final first = scanner.peek;
    if (first == null) fail("syntax error: missing '}'");
    if ('{}:'.contains(first)) fail('syntax error: bad substitution');
    final key = name();
    var ch = scanner.next();
    if (ch == null) fail("syntax error: missing '}'");
    var modifiers = ch;
    final value = lex.env[key];
    if (ch == '}') {
      return value == null && lex.skipUnsetEnv ? '\${$key}' : value ?? '';
    }
    var nullIsUnset = false;
    if (ch == ':') {
      nullIsUnset = true;
      final next = scanner.next();
      if (next == null) fail("syntax error: missing '}'");
      ch = next;
      modifiers += ch;
    }
    if (!nullIsUnset) {
      if (ch == '/') return replace(key);
      if (!'+-?#%'.contains(ch)) {
        fail('unsupported modifier ($modifiers) in substitution');
      }
    }
    final raw = ch == '#' || ch == '%';
    if (nullIsUnset && raw) {
      fail('unsupported modifier ($modifiers) in substitution');
    }
    final word = stopOrMissing('}', raw);
    if (value == null && lex.skipUnsetEnv) return '\${$key$modifiers$word}';
    final unset = value == null || nullIsUnset && value.isEmpty;
    switch (ch) {
      case '-':
        return unset ? word : value;
      case '+':
        return unset ? '' : word;
      case '?':
        if (value == null) {
          fail('$key: ${word.isEmpty ? 'is not allowed to be unset' : word}');
        }
        if (unset) {
          fail('$key: ${word.isEmpty ? 'is not allowed to be empty' : word}');
        }
        return value;
      case '#' || '%':
        final greedy = word.startsWith(ch),
            pattern = word.startsWith(ch) ? word.substring(1) : word;
        return ch == '%'
            ? _trimSuffix(pattern, value ?? '', greedy)
            : _trimPrefix(pattern, value ?? '', greedy);
      default:
        fail('unsupported modifier ($modifiers) in substitution');
    }
  }

  String replace(String key) {
    var op = '/';
    if (scanner.peek == '/') {
      scanner.next();
      op = '//';
    }
    late String pattern;
    try {
      pattern = process('/', true).$1;
    } catch (_) {
      if (scanner.peek == null) fail("syntax error: missing '/' in \${}");
      rethrow;
    }
    final replacement = stopOrMissing('}', true), value = lex.env[key];
    if (value == null && lex.skipUnsetEnv) {
      return '\${$key$op$pattern/$replacement}';
    }
    final re = _shellPattern(pattern, true, false);
    return op == '//'
        ? (value ?? '').replaceAllMapped(re, (_) => replacement)
        : (value ?? '').replaceFirstMapped(re, (_) => replacement);
  }

  String stopOrMissing(String stop, bool raw) {
    try {
      return process(stop, raw).$1;
    } catch (_) {
      if (scanner.peek == null) fail("syntax error: missing '}'");
      rethrow;
    }
  }

  String heredoc() {
    scanner.next();
    if (scanner.peek != '<') return '<';
    scanner.next();
    var space = '';
    while (['\t', '\r', ' '].contains(scanner.peek)) {
      space += scanner.next()!;
    }
    return '<<$space';
  }
}

RegExp _shellPattern(String pattern, bool greedy, bool anchored) {
  final chars = pattern.runes.map(String.fromCharCode).toList();
  var out = anchored ? '^' : '';
  for (var i = 0; i < chars.length; i++) {
    var ch = chars[i];
    if (ch == '*') {
      out += greedy ? '.*' : '.*?';
      continue;
    }
    if (ch == '?') {
      out += '.';
      continue;
    }
    if (ch == r'\') {
      final next = i + 1 < chars.length ? chars[i + 1] : null;
      if (next == '}' || next == '/') continue;
      i++;
      if (next != '*' && next != '?' && next != r'\') {
        throw FormatException(
            "invalid pattern ($pattern) in substitution: invalid escape '\\${next ?? ''}'");
      }
      ch = next!;
    }
    if (r'[]{}.+()|^$*?\'.contains(ch)) out += r'\';
    out += ch;
  }
  return RegExp(out, unicode: true);
}

String _trimPrefix(String pattern, String value, bool greedy) =>
    value.replaceFirst(_shellPattern(pattern, greedy, true), '');
String _reverse(String text) =>
    String.fromCharCodes(text.runes.toList().reversed);
String _reversePattern(String text) {
  final chars = text.runes.map(String.fromCharCode).toList(), out = <String>[];
  for (var i = 0; i < chars.length; i++) {
    if (chars[i] == r'\' && i + 1 < chars.length) {
      out.insertAll(0, [chars[i], chars[i + 1]]);
      i++;
    } else {
      out.insert(0, chars[i]);
    }
  }
  return out.join();
}

String _trimSuffix(String pattern, String value, bool greedy) =>
    _reverse(_trimPrefix(_reversePattern(pattern), _reverse(value), greedy));
