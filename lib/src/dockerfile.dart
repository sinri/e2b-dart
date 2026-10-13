import 'shell_lex.dart';
import 'dockerfile_heredoc.dart';
import 'dart:convert';
import 'errors.dart';
import 'template.dart';

class DockerfileSyntaxException extends E2BException {
  final int? line;
  String get name => 'DockerfileSyntaxError';
  DockerfileSyntaxException(String message, [this.line])
      : super(line == null
            ? 'Dockerfile parse error: $message'
            : 'Dockerfile parse error on line $line: $message');
}

class _Instruction {
  final String name, body;
  final int line;
  final List<DockerHeredoc> heredocs = [];
  _Instruction(this.name, this.body, this.line);
}

List<String> _words(String text, String escape, int line) {
  try {
    return ShellLex(escape, rawQuotes: true, rawEscapes: true)
        .processWords(text);
  } on FormatException catch (error) {
    throw DockerfileSyntaxException(error.message, line);
  }
}

String _expand(String word, String escape, int line,
    [Map<String, String>? vars]) {
  try {
    return ShellLex(escape, env: vars ?? const {}, skipUnsetEnv: vars == null)
        .processWord(word);
  } on FormatException catch (error) {
    throw DockerfileSyntaxException(error.message, line);
  }
}

/// Convert supported Dockerfile syntax into the same template DSL operations.
/// Remaining shell/AST differences are tracked separately in PARITY.md.
String convertDockerfile(String content, Template template) {
  var escape = r'\';
  final instructions = <_Instruction>[];
  final lines = content.replaceFirst(RegExp('^\uFEFF'), '').split('\n');
  var logical = '', firstLine = 0;
  for (var n = 0; n < lines.length; n++) {
    var line = lines[n].replaceFirst(RegExp(r'\r$'), '');
    if (line.trimLeft().startsWith('#')) {
      final directive =
          RegExp(r'^\s*#\s*escape\s*=\s*([\\`])\s*$', caseSensitive: false)
              .firstMatch(line);
      if (directive != null && instructions.isEmpty && logical.isEmpty) {
        escape = directive[1]!;
      }
      continue;
    }
    if (line.trim().isEmpty) continue;
    if (logical.isEmpty) firstLine = n + 1;
    final trailing = line.trimRight();
    if (trailing.endsWith(escape)) {
      logical += trailing.substring(0, trailing.length - 1);
      continue;
    }
    logical += line;
    final match = RegExp(r'^\s*([^\s]+)\s*(.*)$').firstMatch(logical)!;
    final instruction =
        _Instruction(match[1]!.toUpperCase(), match[2]!, firstLine);
    if (['RUN', 'COPY', 'ADD'].contains(instruction.name) &&
        !instruction.body.trimLeft().startsWith('[')) {
      for (final word in _words(instruction.body, r'\', firstLine)) {
        final doc = parseDockerHeredoc(word);
        if (doc == null) continue;
        var terminated = false;
        while (++n < lines.length) {
          final raw = lines[n];
          var marker = raw.replaceFirst(RegExp(r'\r$'), '');
          if (doc.chomp) marker = marker.replaceFirst(RegExp(r'^\t+'), '');
          if (marker == doc.name) {
            terminated = true;
            break;
          }
          doc.content += '$raw${n + 1 < lines.length ? '\n' : ''}';
        }
        if (!terminated) {
          throw DockerfileSyntaxException('unterminated heredoc', firstLine);
        }
        instruction.heredocs.add(doc);
      }
    }
    instructions.add(instruction);
    logical = '';
  }
  if (logical.isNotEmpty) {
    final match = RegExp(r'^\s*([^\s]+)\s*(.*)$').firstMatch(logical)!;
    instructions
        .add(_Instruction(match[1]!.toUpperCase(), match[2]!, firstLine));
  }
  final froms = instructions.where((i) => i.name == 'FROM').toList();
  if (froms.length > 1) {
    throw DockerfileSyntaxException(
        'Multi-stage Dockerfiles are not supported');
  }
  if (froms.isEmpty) {
    throw DockerfileSyntaxException(
        'Dockerfile must contain a FROM instruction');
  }
  final vars = <String, String>{};
  var userChanged = false, workdirChanged = false;
  (bool, List<String>)? cmd, entrypoint;

  (String, Map<String, String>) flags(
      _Instruction i, Map<String, String> specs) {
    var rest = i.body.trimLeft();
    final values = <String, String>{};
    while (rest.startsWith('--')) {
      final word = _words(rest, escape, i.line).first;
      rest = rest.substring(word.length).trimLeft();
      final eq = word.indexOf('=');
      final name = word.substring(2, eq < 0 ? word.length : eq);
      final value = eq < 0 ? null : word.substring(eq + 1);
      final spec = specs[name];
      if (spec == null) {
        throw DockerfileSyntaxException('unknown flag: $name', i.line);
      }
      if (values.containsKey(name)) {
        throw DockerfileSyntaxException(
            'duplicate flag specified: $name', i.line);
      }
      if (spec.startsWith('bool')) {
        if (value != null &&
            value.isNotEmpty &&
            value != 'true' &&
            value != 'false') {
          throw DockerfileSyntaxException(
              'expecting boolean value for flag $name, not: $value', i.line);
        }
      } else if (value == null) {
        throw DockerfileSyntaxException(
            'missing a value on flag: $name', i.line);
      }
      if (spec.endsWith('ignored')) {
        continue;
      }
      values[name] = value ?? 'true';
    }
    return (rest, values);
  }

  List<String> args(String body, _Instruction i) {
    if (body.startsWith('[')) {
      try {
        final value = jsonDecode(body);
        if (value is! List || value.any((e) => e is! String)) {
          throw const FormatException();
        }
        return value.cast<String>();
      } catch (_) {
        throw DockerfileSyntaxException('invalid JSON arguments', i.line);
      }
    }
    return _words(body, escape, i.line);
  }

  String expand(String word, _Instruction i, [bool resolved = false]) =>
      _expand(word, escape, i.line, resolved ? vars : null);
  final (fromBody, _) = flags(froms.single, {'platform': 'string-ignored'});
  final fromArgs = args(fromBody, froms.single);
  if (fromArgs.length != 1 &&
      !(fromArgs.length == 3 && fromArgs[1].toLowerCase() == 'as')) {
    throw DockerfileSyntaxException(
        'FROM requires either one or three arguments', froms.single.line);
  }
  final image = expand(fromArgs.first, froms.single);
  template.setUser('root').setWorkdir('/');
  for (final i in instructions) {
    if (i.name == 'FROM') continue;
    if (i.line < froms.single.line && i.name != 'ARG') {
      throw DockerfileSyntaxException(
          '${i.name} must be preceded by a FROM instruction', i.line);
    }
    final specs = switch (i.name) {
      'RUN' => {
          'mount': 'string-ignored',
          'network': 'string-ignored',
          'security': 'string-ignored',
          'device': 'string-ignored'
        },
      'COPY' || 'ADD' => {
          'chown': 'string',
          'chmod': 'string',
          'from': 'string',
          'link': 'bool-ignored',
          'exclude': 'string-ignored',
          'parents': 'bool-ignored',
          if (i.name == 'ADD') ...{
            'keep-git-dir': 'bool-ignored',
            'checksum': 'string-ignored',
            'unpack': 'bool-ignored'
          }
        },
      _ => <String, String>{},
    };
    if (![
      'RUN',
      'COPY',
      'ADD',
      'WORKDIR',
      'USER',
      'ENV',
      'ARG',
      'CMD',
      'ENTRYPOINT'
    ].contains(i.name)) {
      continue;
    }
    final (body, values) = flags(i, specs);
    final words = args(body, i);
    switch (i.name) {
      case 'RUN':
        if (words.isEmpty) {
          throw DockerfileSyntaxException(
              'RUN requires at least one argument', i.line);
        }
        template.runCmd(body.startsWith('[')
            ? words.map(shellQuote).join(' ')
            : i.heredocs.isNotEmpty
                ? runDockerHeredocs(body, i.heredocs)
                : body);
      case 'WORKDIR' || 'USER':
        if (words.length != 1) {
          throw DockerfileSyntaxException(
              '${i.name} requires exactly one argument', i.line);
        }
        if (i.name == 'USER') {
          template.setUser(expand(words.single, i));
          userChanged = true;
        } else {
          template.setWorkdir(expand(words.single, i));
          workdirChanged = true;
        }
      case 'COPY' || 'ADD':
        if (words.length < 2) {
          throw DockerfileSyntaxException(
              '${i.name} requires at least two arguments', i.line);
        }
        if (values.containsKey('from')) {
          throw DockerfileSyntaxException(
              '${i.name} --from is not supported (multi-stage builds are not supported)',
              i.line);
        }
        int? mode;
        if (values.containsKey('chmod')) {
          final raw = expand(values['chmod']!, i),
              resolved = expand(values['chmod']!, i, true);
          if (!RegExp(r'^[0-7]{3,4}$').hasMatch(resolved)) {
            throw DockerfileSyntaxException(
                'invalid chmod value "$raw"${raw == resolved ? '' : ' (resolves to "$resolved")'}, expected an octal mode such as 0755',
                i.line);
          }
          mode = int.parse(resolved, radix: 8);
        }
        if (parseDockerHeredoc(words.last) != null) {
          throw DockerfileSyntaxException(
              '${i.name} cannot accept a heredoc as a destination', i.line);
        }
        final dest = expand(words.last, i);
        for (final word in words.take(words.length - 1)) {
          final marker = parseDockerHeredoc(word);
          if (marker != null) {
            final docs = i.heredocs.where((d) => d.name == marker.name);
            if (docs.isEmpty) {
              throw DockerfileSyntaxException(
                  'missing heredoc content for ${marker.name}', i.line);
            }
            template.runCmd(
                copyDockerHeredoc(
                    docs.last,
                    dest,
                    values.containsKey('chown')
                        ? expand(values['chown']!, i)
                        : null,
                    mode,
                    i.line),
                user: 'root');
            continue;
          }
          final src = expand(word, i);
          if (i.name == 'ADD' &&
              RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false)
                  .hasMatch(src)) {
            throw DockerfileSyntaxException(
                'ADD from a remote URL is not supported: $src', i.line);
          }
          template.copy(src, dest,
              mode: mode,
              user: values.containsKey('chown')
                  ? expand(values['chown']!, i)
                  : null);
        }
      case 'ENV' || 'ARG':
        if (words.isEmpty) {
          throw DockerfileSyntaxException(
              '${i.name} requires at least one argument', i.line);
        }
        final pairs = <(String, String)>[];
        if (i.name == 'ENV' && !words.first.contains('=')) {
          pairs.add((words.first, words.skip(1).join(' ')));
        } else {
          for (final word in words) {
            final eq = word.indexOf('=');
            if (eq < 0 && i.name == 'ENV') {
              throw DockerfileSyntaxException(
                  'ENV must have two arguments', i.line);
            }
            pairs.add((
              eq < 0 ? word : word.substring(0, eq),
              eq < 0 ? '' : word.substring(eq + 1)
            ));
          }
        }
        final envs = <String, String>{};
        for (final (key, value) in pairs) {
          final name = expand(key, i);
          if (name.isEmpty) {
            throw DockerfileSyntaxException(
                '${i.name} names can not be blank', i.line);
          }
          envs[name] = expand(value, i);
          vars[name] = expand(value, i, true);
        }
        template.setEnvs(envs);
      case 'CMD':
        cmd = (body.startsWith('['), body.startsWith('[') ? words : [body]);
      case 'ENTRYPOINT':
        entrypoint =
            (body.startsWith('['), body.startsWith('[') ? words : [body]);
    }
  }
  String? command;
  if (entrypoint != null) {
    if (entrypoint.$1) {
      final words = [...entrypoint.$2];
      if (cmd != null) {
        words.addAll(cmd.$1 ? cmd.$2 : ['/bin/sh', '-c', ...cmd.$2]);
      }
      if (words.isNotEmpty) command = words.map(shellQuote).join(' ');
    } else if (entrypoint.$2.isNotEmpty) {
      command = entrypoint.$2.first;
    }
  } else if (cmd != null && cmd.$2.isNotEmpty) {
    command = cmd.$1 ? cmd.$2.map(shellQuote).join(' ') : cmd.$2.first;
  }
  if (command != null && command.trim().isNotEmpty) {
    template.setStartCmd(command, waitForTimeout(const Duration(seconds: 20)));
  }
  if (!userChanged) template.setUser('user');
  if (!workdirChanged) template.setWorkdir('/home/user');
  return image;
}
