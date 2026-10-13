import 'dart:io';
import 'dart:convert';
import 'package:e2b/e2b.dart';
import 'package:test/test.dart';

void main() {
  test('Dockerfile syntax errors retain standalone type message and line', () {
    for (final line in <int?>[null, 0, 1, -1]) {
      final error = DockerfileSyntaxException('detail', line);
      expect(error.line, line);
      expect(error.name, 'DockerfileSyntaxError');
      expect(
          error.message,
          line == null
              ? 'Dockerfile parse error: detail'
              : 'Dockerfile parse error on line $line: detail');
      expect(error, isNot(isA<TemplateException>()));
    }
  });

  test('COPY chmod evaluates nested defaults and pattern replacement', () {
    final template = Template().fromDockerfile(r'''
ARG MODE=prefix0755
FROM alpine
COPY --chmod=${MODE#prefix} a /a
COPY --chmod=${MISSING:-${MODE/prefix/}} b /b
''');
    expect(
        template.instructions
            .where((s) => s.type == 'COPY')
            .map((s) => s.args.last),
        ['0755', '0755']);
  });
  test('COPY heredoc expands variables and keeps command substitutions literal',
      () async {
    final directory = await Directory.systemTemp.createTemp('e2b-heredoc-');
    try {
      final destination = '${directory.path}/a b.txt';
      final template =
          Template().fromDockerfile('FROM alpine\nCOPY <<EOF "$destination"\n'
              r'hello $VALUE `echo unsafe` $(echo unsafe) ${MISSING:-fallback}'
              '\nEOF\n');
      final run = template.instructions.firstWhere((s) => s.type == 'RUN');
      expect(run.args[1], 'root');
      final result = await Process.run('/bin/bash', ['-c', run.args[0]],
          environment: {'VALUE': 'world'});
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(await File(destination).readAsString(),
          r'hello world `echo unsafe` $(echo unsafe) fallback' '\n');
    } finally {
      await directory.delete(recursive: true);
    }
  });
  test('quoted COPY heredoc preserves variables and strips tabs when requested',
      () async {
    final directory = await Directory.systemTemp.createTemp('e2b-heredoc-');
    try {
      final destination = '${directory.path}/file';
      final template = Template()
          .fromDockerfile("FROM alpine\nCOPY <<-'EOF' $destination\n\t"
              r'$VALUE $(echo unsafe)'
              '\n\tEOF\n');
      final run = template.instructions.firstWhere((s) => s.type == 'RUN');
      final result = await Process.run('/bin/bash', ['-c', run.args[0]],
          environment: {'VALUE': 'world'});
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(await File(destination).readAsString(),
          r'$VALUE $(echo unsafe)' '\n');
    } finally {
      await directory.delete(recursive: true);
    }
  });
  test('Dockerfile output matches pinned official converter vectors', () async {
    final vectors =
        jsonDecode(await File('test/dockerfile_vectors.json').readAsString())
            as List;
    for (final vector in vectors) {
      expect(vector.containsKey('error'), isFalse);
      expect(Template().fromDockerfile(vector['input'] as String).toJson(),
          vector['expected'],
          reason: vector['input'] as String);
    }
  });
  test(
      'Dockerfile defaults bracket instructions and combine exec entrypoint/CMD',
      () {
    final data = Template().fromDockerfile('''
FROM node:22 AS app
RUN ["echo", "a b"]
ENV A="a b" B=two
ENTRYPOINT ["node", "app.js"]
CMD ["--port", "3000"]
''').toJson();
    expect(data['fromImage'], 'node:22');
    expect(data['startCmd'], 'node app.js --port 3000');
    expect(data['readyCmd'], 'sleep 20');
    expect(data['steps'], [
      {
        'type': 'USER',
        'args': ['root'],
        'force': false
      },
      {
        'type': 'WORKDIR',
        'args': ['/'],
        'force': false
      },
      {
        'type': 'RUN',
        'args': ["echo 'a b'"],
        'force': false
      },
      {
        'type': 'ENV',
        'args': ['A', 'a b', 'B', 'two'],
        'force': false
      },
      {
        'type': 'USER',
        'args': ['user'],
        'force': false
      },
      {
        'type': 'WORKDIR',
        'args': ['/home/user'],
        'force': false
      },
    ]);
  });
  test('COPY JSON and mode variables preserve chown and explicit defaults', () {
    final template = Template().fromDockerfile(r'''
ARG MODE=0755
FROM ubuntu
WORKDIR /app
USER root
COPY --chmod=$MODE --chown=user ["a b", "c", "/app/"]
''');
    final steps = template.instructions;
    expect(steps.where((s) => s.type == 'COPY').map((s) => s.args), [
      ['a b', '/app/', 'user', '0755'],
      ['c', '/app/', 'user', '0755'],
    ]);
    expect(steps.last.type, 'COPY');
    expect(steps.where((s) => s.type == 'USER').length, 2);
  });
  test('continuations and escape directives preserve shell text', () {
    final template = Template().fromDockerfile(
        '# escape=`\nFROM alpine\nRUN echo one `\n && echo two\nENV legacy a b\n');
    expect(template.instructions.firstWhere((s) => s.type == 'RUN').args,
        ['echo one  && echo two']);
    expect(template.instructions.firstWhere((s) => s.type == 'ENV').args,
        ['legacy', 'a b']);
  });
  test('start command follows shell versus exec combination rules', () {
    expect(
        Template()
            .fromDockerfile('FROM alpine\nENTRYPOINT echo hello\nCMD ignored')
            .toJson()['startCmd'],
        'echo hello');
    expect(
        Template()
            .fromDockerfile('FROM alpine\nENTRYPOINT ["exec"]\nCMD echo hi')
            .toJson()['startCmd'],
        "exec /bin/sh -c 'echo hi'");
    expect(
        Template()
            .fromDockerfile('FROM alpine\nCMD []')
            .toJson()
            .containsKey('startCmd'),
        isFalse);
  });
  test('Dockerfile filesystem path is read as content', () async {
    final directory = await Directory.systemTemp.createTemp('e2b-dockerfile-');
    try {
      final file = await File('${directory.path}/Dockerfile')
          .writeAsString('FROM alpine\nUSER user\nWORKDIR /app');
      expect(
          Template().fromDockerfile(file.path).toJson()['fromImage'], 'alpine');
    } finally {
      await directory.delete(recursive: true);
    }
  });
  for (final input in [
    'RUN echo no',
    'FROM a\nFROM b',
    'RUN echo no\nFROM a',
    'FROM a\nCOPY --from=b a /b',
    'FROM a\nADD https://example.com/a /b',
    'FROM a\nCOPY --chmod=hello a /b',
    'FROM a\nRUN --unknown=x echo hi',
    'FROM a\nCOPY --chmod a /b',
    'FROM a\nUSER a b',
    'FROM a\nRUN <<EOF\necho hi',
  ]) {
    test('Dockerfile rejects invalid or unsupported syntax: $input', () {
      expect(() => Template().fromDockerfile(input),
          throwsA(isA<DockerfileSyntaxException>()));
    });
  }
}
