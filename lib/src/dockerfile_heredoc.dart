import 'dockerfile.dart';
import 'template.dart' show shellQuote;

class DockerHeredoc {
  final String name;
  final bool chomp, expand;
  String content = '';
  DockerHeredoc(this.name, this.chomp, this.expand);
  String get chomped => chomp
      ? content.replaceAll(RegExp(r'^\t+', multiLine: true), '')
      : content;
}

DockerHeredoc? parseDockerHeredoc(String word) {
  final match = RegExp(r'^\d*<<(-?)[ \t]*(.*)$').firstMatch(word);
  if (match == null || match[2]!.isEmpty || match[2]!.contains('<')) {
    return null;
  }
  final raw = match[2]!;
  var name = '', quote = '';
  for (var i = 0; i < raw.length; i++) {
    final ch = raw[i];
    if (ch == r'\' && quote != "'" && i + 1 < raw.length) {
      name += raw[++i];
      continue;
    }
    if (ch == quote) {
      quote = '';
      continue;
    }
    if (quote.isEmpty && (ch == "'" || ch == '"')) {
      quote = ch;
      continue;
    }
    if (quote.isEmpty && RegExp(r'\s').hasMatch(ch)) return null;
    name += ch;
  }
  if (quote.isNotEmpty) return null;
  int quotes(String value) => RegExp('[\'"]').allMatches(value).length;
  return DockerHeredoc(name, match[1] == '-', quotes(name) == quotes(raw));
}

String _terminator(String name, String content) {
  var result = 'E2B_HEREDOC_${name.replaceAll(RegExp('[^A-Za-z0-9_]'), '_')}';
  while (content.contains(result)) {
    result += '_';
  }
  return result;
}

String _newline(String content) =>
    content.isEmpty || content.endsWith('\n') ? content : '$content\n';
String runDockerHeredocs(String command, List<DockerHeredoc> docs) {
  if (docs.length == 1 && parseDockerHeredoc(command.trim()) != null) {
    final doc = docs.single, content = docs.single.chomped;
    if (!content.startsWith('#!')) return content;
    final script = shellQuote('/tmp/${doc.name}'),
        terminator = _terminator(doc.name, content);
    return "cat <<'$terminator' >$script\n${_newline(content)}$terminator\n"
        'chmod +x $script && $script\n'
        r'E2B_EXIT=$?; rm -f '
        '$script; exit '
        r'$E2B_EXIT';
  }
  return command + docs.map((d) => '\n${d.content}${d.name}').join();
}

String copyDockerHeredoc(
    DockerHeredoc doc, String dest, String? user, int? mode, int line) {
  var content = doc.chomped;
  if (doc.expand) content = _ExpandableHeredoc(content, line).scan();
  final plain = _terminator(doc.name, content),
      delimiter = doc.expand
          ? _terminator(doc.name, content)
          : "'${_terminator(doc.name, content)}'";
  const target = r'"$E2B_HEREDOC_DEST"';
  var command = dest.endsWith('/')
      ? 'E2B_HEREDOC_DEST=${shellQuote(dest + doc.name)}\n'
      : 'E2B_HEREDOC_DEST=${shellQuote(dest)}\nif [ -d $target ]; then E2B_HEREDOC_DEST=$target/${shellQuote(doc.name)}; fi\n';
  command +=
      'mkdir -p "\$(dirname $target)" && cat <<$delimiter >$target\n${_newline(content)}$plain';
  if (user != null) command += '\nchown ${shellQuote(user)} $target';
  if (mode != null) command += '\nchmod ${mode.toRadixString(8)} $target';
  return command;
}

class _ExpandableHeredoc {
  final String content;
  final int line;
  int i = 0;
  _ExpandableHeredoc(this.content, this.line);
  Never missing(String stop) => throw DockerfileSyntaxException(
      "syntax error: missing ${stop == '/' ? "'/' in \${}" : "'}'"}", line);
  String name() {
    final match =
        RegExp(r'^(?:\p{Nd}+|[@*#?\-$!0]|[\p{L}\p{Nd}_]+)', unicode: true)
            .firstMatch(content.substring(i));
    if (match == null) return '';
    i += match[0]!.length;
    return match[0]!;
  }

  String variable() {
    if (i >= content.length || content[i] != '{') {
      final value = name();
      return value.isEmpty ? r'\$' : '\$$value';
    }
    i++;
    if (i >= content.length) missing('}');
    if ('{}:'.contains(content[i])) {
      throw DockerfileSyntaxException('syntax error: bad substitution', line);
    }
    final value = name();
    if (i >= content.length) missing('}');
    var modifier = content[i++];
    if (modifier == '}') return '\${$value}';
    if (modifier == '/') {
      if (i < content.length && content[i] == '/') modifier += content[i++];
      final pattern = scan('/', true);
      return '\${$value$modifier$pattern/${scan('}', true)}}';
    }
    if (modifier == ':') {
      if (i >= content.length) missing('}');
      modifier += content[i++];
    }
    final op = modifier[modifier.length - 1],
        pattern = modifier.endsWith('#') || modifier.endsWith('%');
    if (!'+-?#%'.contains(op) || (modifier.length == 2 && pattern)) {
      throw DockerfileSyntaxException(
          'unsupported modifier ($modifier) in substitution', line);
    }
    return '\${$value$modifier${scan('}', pattern)}}';
  }

  String scan([String? stop, bool rawEscapes = false]) {
    var out = '';
    while (i < content.length) {
      final ch = content[i++];
      if (ch == stop) return out;
      if (ch == r'\') {
        if (i < content.length) {
          final next = content[i++];
          out += rawEscapes ||
                  next == r'\' ||
                  next == '`' ||
                  next == r'$' ||
                  next == stop
              ? r'\' + next
              : next;
        }
      } else if (ch == r'$') {
        out += variable();
      } else {
        out += ch == '`' ? r'\`' : ch;
      }
    }
    if (stop != null) missing(stop);
    return out;
  }
}
