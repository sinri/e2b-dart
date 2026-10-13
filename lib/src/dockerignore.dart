import 'js_string.dart';
// Port of the pinned E2B PatternMatcher, derived from moby/patternmatcher
// (Apache-2.0). See THIRD_PARTY_NOTICES.md.
import 'errors.dart';

String _clean(String path) {
  final rooted = path.startsWith('/'), parts = <String>[];
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty && parts.last != '..') {
        parts.removeLast();
      } else if (!rooted) {
        parts.add('..');
      }
    } else {
      parts.add(part);
    }
  }
  final result = '${rooted ? '/' : ''}${parts.join('/')}';
  return result.isEmpty ? '.' : result;
}

const _badPattern = 'syntax error in pattern';
Never _invalid() => throw const FormatException(_badPattern);
int _classChar(String pattern, int i, bool escape) {
  if (i >= pattern.length || pattern[i] == '-' || pattern[i] == ']') _invalid();
  if (pattern[i] == r'\' && escape) {
    i++;
    if (i >= pattern.length) _invalid();
  }
  final unit = pattern.codeUnitAt(i);
  i += unit >= 0xd800 && unit <= 0xdbff && i + 1 < pattern.length ? 2 : 1;
  if (i >= pattern.length) _invalid();
  return i;
}

void _validate(String pattern, bool escape) {
  var i = 0;
  while (i < pattern.length) {
    final ch = pattern[i++];
    if (ch == r'\' && escape) {
      if (i >= pattern.length) _invalid();
      i++;
    } else if (ch == '[') {
      if (i < pattern.length && pattern[i] == '^') i++;
      var ranges = 0;
      while (!(ranges > 0 && i < pattern.length && pattern[i] == ']')) {
        i = _classChar(pattern, i, escape);
        if (pattern[i] == '-') i = _classChar(pattern, i + 1, escape);
        ranges++;
      }
      i++;
    }
  }
}

String _translateClass(String body, bool escape) {
  var cls = '', i = 0;
  while (i < body.length) {
    final ch = body[i++];
    if (ch != r'\') {
      cls += ch;
      continue;
    }
    if (!escape || i >= body.length) {
      cls += r'\\';
      continue;
    }
    final next = body[i++];
    if ('dDsSwWfnrtv'.contains(next)) {
      cls += r'\' + next;
    } else if (next == 'a' || next == 'b') {
      cls += next == 'a' ? r'\x07' : r'\x08';
    } else if (['x', 'u', 'U'].contains(next)) {
      final length = {'x': 2, 'u': 4, 'U': 8}[next]!;
      final hex = body.substring(
          i, i + length > body.length ? body.length : i + length);
      if (hex.length < length || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
        throw FormatException('incomplete escape \\$next$hex');
      }
      final code = int.parse(hex, radix: 16);
      if (code > 0x10ffff) throw FormatException('bad escape \\$next$hex');
      cls += '\\u{${code.toRadixString(16)}}';
      i += length;
    } else if (RegExp('[0-7]').hasMatch(next)) {
      var octal = next;
      while (octal.length < 3 &&
          i < body.length &&
          RegExp('[0-7]').hasMatch(body[i])) {
        octal += body[i++];
      }
      final code = int.parse(octal, radix: 8);
      if (code > 255) {
        throw FormatException(
            'octal escape value \\$octal outside of range 0-0o377');
      }
      cls += '\\u{${code.toRadixString(16)}}';
    } else if (RegExp('[A-Za-z0-9]').hasMatch(next)) {
      throw FormatException('bad escape \\$next');
    } else {
      cls += r'^$\.*+?()[]{}|/-'.contains(next) ? r'\' + next : next;
    }
  }
  return cls;
}

bool Function(String) _compile(String pattern, bool escape) {
  _validate(pattern, escape);
  var regex = '^', mode = 'exact', i = 0;
  while (i < pattern.length) {
    final first = i == 0, ch = pattern[i++];
    if (ch == '*') {
      if (i < pattern.length && pattern[i] == '*') {
        i++;
        if (i < pattern.length && pattern[i] == '/') i++;
        if (i >= pattern.length) {
          regex += '.*';
          mode = mode == 'exact' ? 'prefix' : 'regex';
        } else {
          regex += '(.*/)?';
          mode = 'regex';
        }
        if (first) mode = 'suffix';
      } else {
        regex += '[^/]*';
        mode = 'regex';
      }
    } else if (ch == '?') {
      regex += '[^/]';
      mode = 'regex';
    } else if (ch == '[') {
      var j = i;
      if (j < pattern.length && pattern[j] == '^') j++;
      while (j < pattern.length && pattern[j] != ']') {
        if (pattern[j] == r'\' && escape) j++;
        j++;
      }
      regex +=
          '[${_translateClass(pattern.substring(i, j > pattern.length ? pattern.length : j), escape)}${j < pattern.length ? ']' : ''}';
      i = j + 1;
      mode = 'regex';
    } else if (ch == ']') {
      regex += r'\]';
      mode = 'regex';
    } else if (r'.+()|{}$^'.contains(ch)) {
      regex += r'\' + ch;
    } else if (ch == r'\' && escape) {
      if (i < pattern.length) {
        regex += RegExp.escape(pattern[i++]);
        mode = 'regex';
      } else {
        regex += r'\\';
      }
    } else {
      regex += ch;
    }
  }
  switch (mode) {
    case 'exact':
      return (p) => p == pattern;
    case 'prefix':
      final prefix = pattern.substring(0, pattern.length - 2);
      return (p) => p.startsWith(prefix);
    case 'suffix':
      final suffix = pattern.substring(2);
      return (p) =>
          p.endsWith(suffix) ||
          (suffix.startsWith('/') && p == suffix.substring(1));
    default:
      final re = RegExp('$regex\$', unicode: true);
      return re.hasMatch;
  }
}

class _Pattern {
  final bool exclusion;
  final List<String> dirs;
  final bool Function(String) match;
  _Pattern(this.exclusion, this.dirs, this.match);
}

/// Moby-compatible ordered Docker ignore matching, including parent results.
class DockerIgnoreMatcher {
  final bool backslashIsSeparator;
  final List<_Pattern> _compiled = [];
  final List<String> _patterns = [];
  List<String> get patterns => List.unmodifiable(_patterns);
  DockerIgnoreMatcher(List<String> patterns,
      {this.backslashIsSeparator = false}) {
    for (final original in patterns) {
      if (original.startsWith('#')) continue;
      var pattern = jsTrim(original);
      if (pattern.isEmpty) continue;
      final exclusion = pattern.startsWith('!');
      if (exclusion) {
        pattern = jsTrim(pattern.substring(1));
        if (pattern.isEmpty) {
          throw TemplateException(
              "Invalid ignore pattern '$original': illegal exclusion pattern");
        }
      }
      if (backslashIsSeparator) pattern = pattern.replaceAll(r'\', '/');
      pattern = _clean(pattern);
      if (pattern.length > 1 && pattern.startsWith('/')) {
        pattern = pattern.substring(1);
      }
      try {
        _compiled.add(_Pattern(exclusion, pattern.split('/'),
            _compile(pattern, !backslashIsSeparator)));
      } catch (error) {
        final message =
            error is FormatException ? error.message : error.toString();
        throw TemplateException("Invalid ignore pattern '$original': $message");
      }
      _patterns.add('${exclusion ? '!' : ''}$pattern');
    }
  }
  String _slash(String path) =>
      backslashIsSeparator ? path.replaceAll(r'\', '/') : path;
  bool matches(String path) {
    final segments = _slash(path).split('/');
    var parents = <bool>[];
    var matched = false;
    for (var depth = 1; depth <= segments.length; depth++) {
      final current = segments.take(depth).join('/');
      matched = false;
      parents = List.generate(_compiled.length, (index) {
        final pattern = _compiled[index];
        var match = index < parents.length ? parents[index] : false;
        if (!match) {
          if (pattern.exclusion != matched) return false;
          match = pattern.match(current);
        }
        if (match) matched = !pattern.exclusion;
        return match;
      });
    }
    return matched;
  }

  bool mayMatchUnder(String path) {
    final segments = _slash(path).split('/');
    return _compiled.any((pattern) {
      if (!pattern.exclusion) return false;
      for (var i = 0; i < segments.length; i++) {
        if (i >= pattern.dirs.length) return false;
        final segment = pattern.dirs[i];
        if (segment.contains('**')) return true;
        if (!RegExp(r'[*?[\\]').hasMatch(segment) && segment != segments[i]) {
          return false;
        }
      }
      return pattern.dirs.length > segments.length;
    });
  }
}
