import 'dart:convert';
import 'dart:io';
import 'package:e2b/e2b.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

http.Response json(Object data, [int status = 200]) =>
    http.Response(jsonEncode(data), status,
        headers: {'content-type': 'application/json'});
void main() {
  test(
      'Template static management forwards options and preserves injected client',
      () async {
    final paths = <String>[];
    final client = ApiClient(
        apiKey: 'bound',
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          expect(request.headers['x-api-key'], 'call');
          if (request.url.path.endsWith('/status')) {
            expect(request.url.queryParameters['logsOffset'], '1.5');
            return json({
              'templateID': 'id',
              'buildID': 'build',
              'status': 'ready',
              'logs': []
            });
          }
          if (request.url.path.endsWith('/tags') && request.method == 'GET') {
            return json([]);
          }
          if (request.method == 'POST') {
            return json({'templateID': 'id', 'buildID': 'build', 'tags': []});
          }
          return json({});
        }));
    final options = RequestOptions(apiKey: 'call');
    try {
      expect(await Template.exists('name', options: options, client: client),
          isTrue);
      expect(
          await Template.aliasExists('name', options: options, client: client),
          isTrue);
      await Template.assignTags('name', ['stable'],
          options: options, client: client);
      await Template.removeTags('name', ['stable'],
          options: options, client: client);
      expect(await Template.getTags('id', options: options, client: client),
          isEmpty);
      await Template.getBuildStatus(
          BuildInfo(name: 'name', templateId: 'id', buildId: 'build'),
          logsOffset: 1.5,
          options: options,
          client: client);
      for (final build in [Template.build, Template.buildInBackground]) {
        await expectLater(build(Template(), '', client: client),
            throwsA(isA<TemplateException>()));
      }
      expect(paths.length, 6);
      expect(await Template.exists('again', options: options, client: client),
          isTrue);
    } finally {
      client.close();
    }
  });

  test('official template type aliases use the same Dart builder', () async {
    final TemplateBase base = TemplateBase();
    final TemplateBuilder builder = base.fromPythonImage('3');
    final TemplateClass template = builder.runCmd('echo ready');
    expect(identical(base, template), isTrue);
    expect(TemplateBase.toDockerfile(template), contains('FROM python:3'));
    expect(await Template.toJSON(template, computeHashes: false),
        contains('echo ready'));
  });

  test('local GCP text matches Node malformed UTF8 and BOM handling', () {
    final directory = Directory.systemTemp.createTempSync('e2b-node-utf8-');
    addTearDown(() => directory.deleteSync(recursive: true));
    File('${directory.path}/credentials')
        .writeAsBytesSync([0xef, 0xbb, 0xbf, 0xff, 0x61, 0xe2, 0x82]);
    final builder = Template(fileContextPath: directory.path)
        .fromGCPRegistry('image', serviceAccountJSON: 'credentials');
    expect(builder.toJson()['fromImageRegistry']['serviceAccountJson'],
        '\uFEFF\uFFFDa\uFFFD');
  });

  test('JSON serialization reads local ignore files only for hashed COPY',
      () async {
    final directory = Directory.systemTemp.createTempSync('e2b-json-ignore-');
    addTearDown(() => directory.deleteSync(recursive: true));
    File('${directory.path}/.dockerignore').writeAsBytesSync([255]);
    final builder = Template(fileContextPath: directory.path)
        .fromImage('alpine')
        .runCmd('echo ok');
    expect(jsonDecode(await Template.toJSON(builder))['fromImage'], 'alpine');
    builder.copy('missing', '/dest');
    final withoutHashes =
        jsonDecode(await Template.toJSON(builder, computeHashes: false));
    expect(withoutHashes['steps'].last.containsKey('filesHash'), isFalse);
    await expectLater(
        Template.toJSON(builder), throwsA(isA<TemplateException>()));
  });

  test('Dockerfile export follows instruction projection and generic errors',
      () {
    final builder = Template()
        .fromImage('alpine')
        .setEnvs({'A': 'one', 'B': 'two words'})
        .setWorkdir('/app')
        .setUser('user')
        .runCmd(['echo a', 'echo b'], user: 'root')
        .setStartCmd('echo ready', 'true');
    expect(
        Template.toDockerfile(builder),
        'FROM alpine\nENV A=one B=two words\nWORKDIR /app\nUSER user\n'
        'RUN echo a && echo b\nENTRYPOINT echo ready\n');
    expect(
        () => Template.toDockerfile(Template().fromTemplate('base')),
        throwsA(isA<E2BException>()
            .having((e) => e is TemplateException, 'template-specific', isFalse)
            .having(
                (e) => e.message,
                'message',
                'Cannot convert template built from another template to Dockerfile. '
                    'Templates based on other templates can only be built using the E2B API.')));
  });

  test('template git clone depth preserves official number formatting', () {
    for (final entry in <num, String?>{
      0: null,
      double.nan: null,
      1.0: '1',
      0.5: '0.5',
      -0.5: '-0.5',
      1e21: '1e+21',
      double.infinity: 'Infinity',
    }.entries) {
      final builder = Template().gitClone('https://example.test/repo',
          branch: 'a b', path: 'dir name', depth: entry.key, user: 'user');
      final step = builder.instructions.single;
      final expected =
          "git clone https://example.test/repo --branch 'a b' --single-branch"
          "${entry.value == null ? '' : ' --depth ${entry.value}'} 'dir name'";
      expect(step.args, [expected, 'user']);
    }
  });

  test(
      'GCP credential read failure preserves official partial builder mutation',
      () {
    final directory = Directory.systemTemp.createTempSync('e2b-gcp-failure-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final builder = Template(fileContextPath: directory.path)
        .fromImage('private', username: 'u', password: 'p')
        .fromTemplate('base-template')
        .skipCache();
    final before = builder.toJson();
    expect(
        () => builder.fromGCPRegistry('gcp/new',
            serviceAccountJSON: 'missing.json'),
        throwsA(isA<FileSystemException>()));
    final after = builder.toJson();
    expect(after['fromImage'], 'gcp/new');
    expect(after.containsKey('fromTemplate'), isFalse);
    expect(after['fromImageRegistry'], before['fromImageRegistry']);
    expect(after['force'], before['force']);
  });

  test('template ignore patterns retain the caller array reference', () {
    final patterns = ['initial'];
    final template = Template(fileIgnorePatterns: patterns);
    patterns.add('later');
    expect(template.fileIgnorePatterns, ['initial', 'later']);
    patterns.remove('initial');
    expect(template.fileIgnorePatterns, ['later']);
  });

  test('registry credential errors match official message before mutation', () {
    for (final credentials in [
      ['', 'password'],
      ['username', ''],
      ['', ''],
      ['username', null],
      [null, 'password'],
    ]) {
      final template = Template().fromImage('original');
      expect(
          () => template.fromImage('changed',
              username: credentials[0], password: credentials[1]),
          throwsA(isA<InvalidArgumentException>().having(
              (e) => e.message,
              'message',
              'Both username and password are required when providing registry credentials')));
      expect(template.toJson()['fromImage'], 'original');
    }
  });

  test('build resource numbers are forwarded without integer restrictions',
      () async {
    final requests = <http.Request>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          requests.add(request);
          return request.url.path == '/v3/templates'
              ? json({'templateID': 't', 'buildID': 'b', 'tags': []})
              : http.Response('', 204);
        }));
    addTearDown(client.close);
    await client.templates.buildInBackgroundWithOptions(
        Template(),
        const BuildOptions(
            alias: 'demo', cpuCount: 0.5, memoryMB: -0.5, minFreeDiskMb: 1.25));
    expect(jsonDecode(requests.first.body), {
      'name': 'demo',
      'cpuCount': 0.5,
      'memoryMB': -0.5,
      'minFreeDiskMb': 1.25
    });
    requests.clear();
    await client.templates.buildInBackground(Template(), 'demo',
        cpuCount: double.nan,
        memoryMB: double.infinity,
        minFreeDiskMb: double.negativeInfinity);
    expect(jsonDecode(requests.first.body), {
      'name': 'demo',
      'cpuCount': null,
      'memoryMB': null,
      'minFreeDiskMb': null
    });
    requests.clear();
    await client.templates.buildInBackground(Template(), 'demo');
    expect(jsonDecode(requests.first.body), {'name': 'demo'});
  });

  test(
      'structured build options forward alias resources callbacks and connection',
      () async {
    final requests = <http.Request>[];
    final logs = <LogEntry>[];
    final client = E2BClient(
        apiKey: 'bound',
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/v3/templates') {
            return json({'templateID': 't', 'buildID': 'b', 'tags': []});
          }
          return http.Response('', 204);
        }));
    addTearDown(client.close);
    final template = Template();
    final result = await client.templates.buildInBackgroundWithOptions(
        template,
        BuildOptions(
            alias: 'demo',
            tags: [],
            cpuCount: 0,
            memoryMB: 0,
            minFreeDiskMb: 0,
            skipCache: true,
            onBuildLogs: logs.add,
            connection: RequestOptions(apiKey: 'call')));
    expect(result.name, 'demo');
    expect(jsonDecode(requests.first.body), {
      'name': 'demo',
      'tags': [],
      'cpuCount': 0,
      'memoryMB': 0,
      'minFreeDiskMb': 0
    });
    expect(requests.every((r) => r.headers['X-API-Key'] == 'call'), isTrue);
    expect(jsonDecode(requests.last.body)['force'], isTrue);
    expect(logs.length, 4);
  });

  test('build validates before logging and finalizes a failing start callback',
      () async {
    var requests = 0;
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((_) async {
          requests++;
          return json({});
        }));
    addTearDown(client.close);
    final entries = <LogEntry>[];
    await expectLater(
        client.templates.build(Template(), '', onBuildLogs: entries.add),
        throwsA(isA<TemplateException>()));
    expect(entries, isEmpty);
    final failure = StateError('start failed');
    await expectLater(
        client.templates.build(Template(), 'demo', onBuildLogs: (entry) {
          entries.add(entry);
          if (entry is LogEntryStart) throw failure;
        }),
        throwsA(same(failure)));
    expect(entries.map((e) => e.message), ['Build started', 'Build finished']);
    expect(requests, 0);
  });

  test('background build stops at a failing stage log callback', () async {
    final stages = [
      'Requesting build for template: demo',
      'Template created with ID: t, Build ID: b',
      'All file uploads completed',
      'Starting building...',
    ];
    for (var failingStage = 0; failingStage < stages.length; failingStage++) {
      final requests = <http.Request>[];
      final client = E2BClient(
          apiKey: 'key',
          httpClient: MockClient((request) async {
            requests.add(request);
            return json({'templateID': 't', 'buildID': 'b', 'tags': []});
          }));
      addTearDown(client.close);
      final failure = StateError('callback failed');
      final messages = <String>[];
      await expectLater(
          client.templates.buildInBackground(Template(), 'demo', tags: [],
              onBuildLogs: (entry) {
            messages.add(entry.message);
            if (entry.message == stages[failingStage]) throw failure;
          }),
          throwsA(same(failure)));
      expect(messages, stages.take(failingStage + 1));
      expect(requests.length, failingStage == 0 ? 0 : 1);
      expect(requests.every((r) => r.url.path == '/v3/templates'), isTrue);
    }
  });

  test('copyItems forwards per-item flags to every expanded source', () {
    final builder = Template().copyItems([
      const CopyItem(['a', 'b'], '/dest',
          user: '', mode: 0, gzip: false, resolveSymlinks: false),
      const CopyItem('c', '/other',
          user: 'root', forceUpload: true, gzip: true, resolveSymlinks: true),
    ]);
    expect(builder.instructions.map((step) => step.toJson()), [
      for (final src in ['a', 'b'])
        {
          'type': 'COPY',
          'args': [src, '/dest', '', '0000'],
          'force': false,
          'resolveSymlinks': false,
          'gzip': false,
        },
      {
        'type': 'COPY',
        'args': ['c', '/other', 'root', ''],
        'force': true,
        'forceUpload': true,
        'resolveSymlinks': true,
        'gzip': true,
      }
    ]);
    expect(identical(builder.copyItems([]), builder), isTrue);
  });

  test('build status offset omits absent values and preserves JS numbers',
      () async {
    final requests = <http.Request>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          requests.add(request);
          return json({'templateID': 't', 'buildID': 'b', 'status': 'ready'});
        }));
    addTearDown(client.close);
    final info = BuildInfo(name: 'name', templateId: 't/a', buildId: 'b c');
    for (final offset in <num?>[null, 0, -1, 0.5, 1.0, 1e21]) {
      await client.templates.getBuildStatus(info, logsOffset: offset);
    }
    expect(requests.map((r) => r.url.queryParameters['logsOffset']),
        [null, '0', '-1', '0.5', '1', '1e+21']);
    expect(requests.first.url.pathSegments,
        ['templates', 't/a', 'builds', 'b c', 'status']);
  });

  test('build status preserves wire logs and converts reason log entries', () {
    final response = TemplateBuildStatusResponse({
      'templateID': 't',
      'buildID': 'b',
      'status': 'error',
      'logs': ['legacy wire log'],
      'logEntries': [
        {
          'timestamp': '2026-10-12T08:00:00.123456+08:00',
          'level': 'error',
          'message': '\u001b[31mfailed\u001b[0m',
        }
      ],
      'reason': {
        'message': 'step failed',
        'step': '',
        'logEntries': [
          {
            'timestamp': '2026-10-12T08:00:00.123456+08:00',
            'level': 'warn',
            'message': '\u001b[33mreason\u001b[0m',
          }
        ]
      },
    });
    expect(response.logs, ['legacy wire log']);
    expect(response.logEntries.single.message, 'failed');
    expect(response.reason!.message, 'step failed');
    expect(response.reason!.step, '');
    expect(response.reason!.logEntries.single.message, 'reason');
    expect(response.reason!.logEntries.single.timestamp.toIso8601String(),
        '2026-10-12T00:00:00.123Z');
    final absent = BuildStatusReason({'message': 'failed'});
    expect(absent.step, isNull);
    expect(absent.logEntries, isEmpty);
  });

  test('build status type represents states separately from response objects',
      () {
    for (final TemplateBuildStatus state in [
      'building',
      'waiting',
      'ready',
      'error'
    ]) {
      final response = TemplateBuildStatusResponse({
        'templateID': 't',
        'buildID': 'b',
        'status': state,
      });
      expect(response.status, state);
      expect(response, isNot(isA<String>()));
    }
  });

  test('template response alias exposes official IDs and tag date precision',
      () {
    final TemplateBuildStatusResponse response = TemplateBuildStatusResponse({
      'templateID': 't',
      'buildID': 'b',
      'status': 'ready',
    });
    expect(response.templateID, 't');
    expect(response.buildID, 'b');
    expect(response.logEntries, isEmpty);
    final tag = TemplateTag({
      'tag': 'latest',
      'buildID': 'b',
      'createdAt': '2026-10-12T08:00:00.123456+08:00'
    });
    expect(tag.createdAt.toIso8601String(), '2026-10-12T00:00:00.123Z');
  });

  test('package helpers treat empty string like omitted packages', () {
    final template = Template()
        .pipInstall('')
        .npmInstall(packages: '')
        .bunInstall(packages: '')
        .pipInstall(<String>[]);
    expect(template.instructions.map((s) => s.args), [
      ['pip install .', 'root'],
      ['npm install'],
      ['bun install'],
      ['pip install', 'root'],
    ]);
  });

  test('Dockerfile import forces image and layers after skipCache', () {
    final template =
        Template().skipCache().fromDockerfile('FROM alpine\nRUN echo hi');
    expect(template.toJson()['force'], true);
    expect(template.instructions.every((s) => s.force), true);
    expect(template.toJson()['fromImage'], 'alpine');
  });

  for (final status in [400, 403, 404, 401, 429, 503]) {
    test('template API errors use stage types for HTTP $status', () async {
      final client = E2BClient(
          apiKey: 'key',
          retries: 0,
          httpClient:
              MockClient((_) async => json({'message': 'rejected'}, status)));
      addTearDown(client.close);
      Matcher special(Matcher ordinary) => switch (status) {
            401 => isA<AuthenticationException>(),
            429 => isA<RateLimitException>(),
            503 => isA<ServiceBusyException>(),
            _ => ordinary,
          };
      await expectLater(client.templates.buildInBackground(Template(), 'name'),
          throwsA(special(isA<BuildException>())));
      await expectLater(
          client.templates.getBuildStatus(
              BuildInfo(name: 'name', templateId: 't', buildId: 'b')),
          throwsA(special(isA<BuildException>())));
      await expectLater(client.templates.getTags('t'),
          throwsA(special(isA<TemplateException>())));
    });
  }

  test('missing build API response data reports BuildException', () async {
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((_) async => http.Response('', 204)));
    addTearDown(client.close);
    await expectLater(
        client.templates.buildInBackground(Template(), 'name'),
        throwsA(isA<BuildException>()
            .having((e) => e.message, 'message', 'Failed to request build')));
    await expectLater(
        client.templates.getBuildStatus(
            BuildInfo(name: 'name', templateId: 't', buildId: 'b')),
        throwsA(isA<BuildException>().having(
            (e) => e.message, 'message', 'Failed to get build status')));
  });

  test('build logs strip all upstream ANSI controls and use JS precision', () {
    final entry = LogEntry(
      DateTime.utc(2026, 1, 2, 3, 4, 5, 123, 456),
      'info',
      '\x1b[31mred\x1b[0m '
          '\x1b]8;;https://example.com\x07link\x1b]8;;\x1b\\ '
          '\x1bPdiscard\x9c\x9b32mgreen\x9b0m',
    );
    expect(entry.message, 'red link green');
    expect(
        entry.toString(), '[2026-01-02T03:04:05.123Z] [info] red link green');
  });
  test('ready helpers and shell quoting match official commands', () {
    expect(waitForPort(80).getCmd(), r'[ -n "$(ss -Htuln sport = :80)" ]');
    expect(waitForURL('http://localhost:3000').getCmd(),
        'curl -s -o /dev/null -w "%{http_code}" http://localhost:3000 | grep -q "200"');
    expect(waitForProcess("a'b").getCmd(), "pgrep 'a'\"'\"'b' > /dev/null");
    expect(waitForFile('/tmp/a b').getCmd(), "[ -f '/tmp/a b' ]");
    expect(
        waitForTimeout(const Duration(milliseconds: 999)).getCmd(), 'sleep 1');
    expect(
        waitForTimeout(const Duration(milliseconds: 2500)).getCmd(), 'sleep 2');
  });
  test('builder serializes instructions and sticky cache invalidation', () {
    final builder = Template()
        .fromPythonImage('3.12')
        .setEnvs({'A': 'one', 'B': 'two'})
        .runCmd(['echo one', 'echo two'], user: 'root')
        .skipCache()
        .setWorkdir('/app')
        .setUser('user')
        .setStartCmd('python app.py', waitForPort(8000));
    expect(builder.toJson(), {
      'fromImage': 'python:3.12',
      'force': false,
      'startCmd': 'python app.py',
      'readyCmd': r'[ -n "$(ss -Htuln sport = :8000)" ]',
      'steps': [
        {
          'type': 'ENV',
          'args': ['A', 'one', 'B', 'two'],
          'force': false
        },
        {
          'type': 'RUN',
          'args': ['echo one && echo two', 'root'],
          'force': false
        },
        {
          'type': 'WORKDIR',
          'args': ['/app'],
          'force': true
        },
        {
          'type': 'USER',
          'args': ['user'],
          'force': true
        },
      ]
    });
    expect(Template.toDockerfile(builder),
        'FROM python:3.12\nENV A=one B=two\nRUN echo one && echo two\nWORKDIR /app\nUSER user\nENTRYPOINT python app.py\n');
    expect(Template().skipCache().fromBaseImage().toJson()['force'], true);
  });
  test('image convenience methods match fixed upstream defaults', () {
    final pairs = [
      [Template().fromDebianImage(), 'debian:stable'],
      [Template().fromUbuntuImage(), 'ubuntu:latest'],
      [Template().fromFedoraImage(), 'fedora:44'],
      [Template().fromAlpineImage(), 'alpine:3.24'],
      [Template().fromArchImage(), 'archlinux:latest'],
      [Template().fromPythonImage(), 'python:3'],
      [Template().fromNodeImage(), 'node:lts'],
      [Template().fromBunImage(), 'oven/bun:latest'],
    ];
    for (final pair in pairs) {
      expect((pair[0] as Template).toJson()['fromImage'], pair[1]);
    }
  });
  test('file/package helpers preserve command argument order and user', () {
    final builder = Template()
        .remove(['a b', 'x'], recursive: true, force: true)
        .rename('a', 'b', force: true)
        .makeDir('a', mode: 493)
        .makeSymlink('a', 'b', force: true)
        .pipInstall(['numpy'])
        .npmInstall(packages: 'typescript', global: true, dev: true)
        .bunInstall(packages: 'vitest', dev: true)
        .aptInstall('curl', noInstallRecommends: true, fixMissing: true)
        .gitClone('https://example.com/a.git',
            branch: 'main', depth: 1, path: '/app');
    expect(builder.instructions.map((s) => s.args.first), [
      "rm -r -f 'a b' x",
      'mv a b -f',
      'mkdir -p -m 0755 a',
      'ln -s -f a b',
      'pip install numpy',
      'npm install -g --save-dev typescript',
      'bun install --dev vitest',
      'apt-get update && DEBIAN_FRONTEND=noninteractive DEBCONF_NOWARNINGS=yes apt-get install -y --no-install-recommends --fix-missing curl',
      'git clone https://example.com/a.git --branch main --single-branch --depth 1 /app',
    ]);
    expect(builder.instructions[4].args.last, 'root');
  });
  test('COPY accepts normalized in-context paths and emits octal modes', () {
    final builder = Template().copy(['foo/../bar', '..myconfig'], '/app',
        mode: 420, forceUpload: true);
    expect(builder.instructions.first.toJson(), {
      'type': 'COPY',
      'args': ['foo/../bar', '/app', '', '0644'],
      'force': true,
      'forceUpload': true
    });
    expect(() => Template().copy('../escape', '/app'),
        throwsA(isA<TemplateException>()));
    expect(() => Template().copy('/absolute', '/app'),
        throwsA(isA<TemplateException>()));
  });
  test(
      'registry credentials validate before mutating and GCP strings are file paths',
      () {
    final builder = Template().fromNodeImage();
    expect(() => builder.fromImage('private', username: 'u'),
        throwsA(isA<InvalidArgumentException>()));
    expect(builder.toJson()['fromImage'], 'node:lts');
    expect(
        builder
            .fromAWSRegistry('aws/image',
                accessKeyId: 'id', secretAccessKey: 'secret', region: 'r')
            .toJson()['fromImageRegistry'],
        {
          'type': 'aws',
          'awsAccessKeyId': 'id',
          'awsSecretAccessKey': 'secret',
          'awsRegion': 'r'
        });
    final directory = Directory.systemTemp.createTempSync('e2b-gcp');
    addTearDown(() => directory.deleteSync(recursive: true));
    File('${directory.path}/account.json')
        .writeAsStringSync('{"client_email":"a"}\n');
    expect(
        Template(fileContextPath: directory.path)
            .fromGCPRegistry('image', serviceAccountJSON: 'account.json')
            .toJson()['fromImageRegistry'],
        {'type': 'gcp', 'serviceAccountJson': '{"client_email":"a"}\n'});
  });
  test('MCP and devcontainer guards preserve official preconditions', () {
    expect(() => Template().addMcpServer('x'), throwsA(isA<BuildException>()));
    expect(
        Template()
            .fromTemplate('mcp-gateway')
            .addMcpServer(['a', 'b'])
            .instructions
            .single
            .args,
        ['mcp-gateway pull a b', 'root']);
    expect(() => Template().betaDevContainerPrebuild('/a'),
        throwsA(isA<BuildException>()));
    final builder = Template()
        .fromTemplate('devcontainer')
        .betaSetDevContainerStart('/a b');
    expect(builder.toJson()['readyCmd'], '[ -f /devcontainer.up ]');
    expect(() => Template.toDockerfile(builder), throwsA(isA<E2BException>()));
  });
  test('template alias existence distinguishes forbidden and absent', () async {
    var status = 403;
    final client = E2BClient(
        apiKey: 'key', httpClient: MockClient((_) async => json({}, status)));
    expect(await client.templates.exists('a'), true);
    status = 404;
    expect(await client.templates.aliasExists('a'), false);
    status = 401;
    await expectLater(
        client.templates.exists('a'), throwsA(isA<AuthenticationException>()));
  });
  test('build requests exact schema and drains terminal logs', () async {
    var polls = 0;
    final received = <LogEntry>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          if (r.url.path == '/v3/templates') {
            expect(jsonDecode(r.body), {
              'name': 'demo:dev',
              'tags': ['stable'],
              'minFreeDiskMb': 0
            });
            return json({
              'templateID': 't',
              'buildID': 'b',
              'tags': ['dev', 'stable']
            });
          }
          if (r.method == 'POST') {
            expect(r.url.path, '/v2/templates/t/builds/b');
            expect(jsonDecode(r.body)['fromImage'], 'python:3');
            return http.Response('', 204);
          }
          expect(r.url.path, '/templates/t/builds/b/status');
          expect(r.url.queryParameters['logsOffset'], '$polls');
          polls++;
          return json({
            'templateID': 't',
            'buildID': 'b',
            'status': polls == 1 ? 'building' : 'ready',
            'logEntries': polls <= 2
                ? [
                    {
                      'timestamp': '2026-10-12T00:00:00Z',
                      'level': 'info',
                      'message': 'line$polls'
                    }
                  ]
                : [],
            'logs': []
          });
        }));
    final info = await client.templates.build(
        Template().fromPythonImage(), 'demo:dev',
        tags: ['stable'],
        minFreeDiskMb: 0,
        onBuildLogs: received.add,
        pollInterval: Duration.zero);
    expect(info.tags, ['dev', 'stable']);
    expect(polls, 3);
    expect(received.first, isA<LogEntryStart>());
    expect(received.last, isA<LogEntryEnd>());
    expect(received.where((e) => e.level == 'info').map((e) => e.message), [
      'Requesting build for template: demo:dev with tags stable',
      'Template created with ID: t, Build ID: b',
      'All file uploads completed',
      'Starting building...',
      'Waiting for logs...',
      'line1',
      'line2'
    ]);
  });
  test('failed build drains logs and retains failing step', () async {
    var polls = 0;
    final logs = <LogEntry>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          if (r.url.path == '/v3/templates') {
            return json({'templateID': 't', 'buildID': 'b'});
          }
          if (r.method == 'POST') return http.Response('', 204);
          return json({
            'templateID': 't',
            'buildID': 'b',
            'status': 'error',
            'logEntries': polls++ == 0
                ? [
                    {
                      'timestamp': '2026-10-12T00:00:00Z',
                      'level': 'error',
                      'message': 'bad'
                    }
                  ]
                : [],
            'reason': {'message': 'failed', 'step': '2'}
          });
        }));
    await expectLater(
        client.templates.build(Template(), 'demo', onBuildLogs: logs.add),
        throwsA(isA<BuildException>().having((e) => e.step, 'step', '2')));
    expect(polls, 2);
    expect(logs.last, isA<LogEntryEnd>());
  });
  test('tag APIs use target on assignment and name on removal', () async {
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          if (r.method == 'POST') {
            expect(jsonDecode(r.body), {
              'target': 'demo:dev',
              'tags': ['stable']
            });
            return json({
              'buildID': 'b',
              'tags': ['stable']
            });
          }
          if (r.method == 'DELETE') {
            expect(jsonDecode(r.body), {
              'name': 'demo',
              'tags': ['stable']
            });
            return http.Response('', 204);
          }
          return json([
            {'tag': 'dev', 'buildID': 'b', 'createdAt': '2026-10-12T00:00:00Z'}
          ]);
        }));
    expect(
        (await client.templates.assignTags('demo:dev', 'stable')).buildId, 'b');
    await client.templates.removeTags('demo', ['stable']);
    expect(
        (await client.templates.getTags('demo')).single.createdAt.isUtc, true);
  });
}
