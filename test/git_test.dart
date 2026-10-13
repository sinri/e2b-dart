import 'package:e2b/e2b.dart';
import 'package:test/test.dart';
import 'dart:convert';
import 'dart:io';

class RecordingCommands implements Commands {
  final calls = <Invocation>[];
  String stdout = '';
  final replies = <Object>[];
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation);
    if (replies.isNotEmpty) {
      final next = replies.removeAt(0);
      if (next is CommandResult && next is! Exception) {
        return Future.value(next);
      }
      return Future<CommandResult>.error(next);
    }
    return Future.value(
        CommandResult(pid: 1, exitCode: 0, stdout: stdout, stderr: ''));
  }
}

void main() {
  test('HTTP numeric hosts match deterministic Node URL corpus', () {
    final rows =
        jsonDecode(File('test/ipv4_vectors.json').readAsStringSync()) as List;
    for (final row in rows.cast<Map<String, dynamic>>()) {
      final input = row['input'] as String;
      final host = row['host'] as String?;
      if (host == null) {
        expect(() => withGitCredentials('https://$input/r', 'u', 'p'),
            throwsA(isA<InvalidArgumentException>()),
            reason: input);
      } else {
        expect(withGitCredentials('https://$input/r', 'u', 'p'),
            'https://u:p@$host/r',
            reason: input);
      }
    }
    for (final host in ['exa%3Ample.test', '%5B%3A%3A1%5D']) {
      expect(() => withGitCredentials('https://$host/r', 'u', 'p'),
          throwsA(isA<InvalidArgumentException>()));
    }
  });

  test('HTTP percent-encoded hosts decode before validation and IPv4 parsing',
      () {
    for (final entry in {
      '%65xample.test': 'example.test',
      '%31%32%37.1': '127.0.0.1',
      '[::1]': '[::1]',
    }.entries) {
      expect(withGitCredentials('https://${entry.key}/r', 'u', 'p'),
          'https://u:p@${entry.value}/r');
    }
    for (final host in [
      'exa%23mple.test',
      'exa%2Fmple.test',
      'exa%25mple.test',
      'exa%00mple.test',
      '%ff.test',
    ]) {
      expect(() => withGitCredentials('https://$host/r', 'u', 'p'),
          throwsA(isA<InvalidArgumentException>()));
      expect(deriveGitRepoDir('https://$host/r'), isNull);
      expect(stripGitCredentials('https://u:p@$host/r'), 'https://u:p@$host/r');
    }
  });

  test('HTTP Git hosts follow WHATWG numeric IPv4 rules', () {
    for (final entry in {
      '127.1': '127.0.0.1',
      '0x7f.1': '127.0.0.1',
      '0177.0.0.1': '127.0.0.1',
      '2130706433': '127.0.0.1',
      '1.2.65535': '1.2.255.255',
      '127.0.0.1.': '127.0.0.1',
    }.entries) {
      expect(withGitCredentials('https://${entry.key}/r', 'u', 'p'),
          'https://u:p@${entry.value}/r');
    }
    for (final host in ['1.2.3.256', '1.2.3.09', '4294967296', 'a.1']) {
      expect(() => withGitCredentials('https://$host/r', 'u', 'p'),
          throwsA(isA<InvalidArgumentException>()));
      expect(stripGitCredentials('https://u:p@$host/r'), 'https://u:p@$host/r');
      expect(deriveGitRepoDir('https://$host/r'), isNull);
    }
  });

  test('credential setters match Node ASCII and Unicode vectors', () {
    final vectors =
        jsonDecode(File('test/git_credential_vectors.json').readAsStringSync())
            as List;
    for (final row in vectors.cast<Map<String, dynamic>>()) {
      final input = row['input'] as String;
      final encoded = row['encoded'] as String;
      expect(withGitCredentials('https://example.test/repo', input, input),
          'https://$encoded:$encoded@example.test/repo',
          reason: jsonEncode(input));
    }
  });

  test('HTTP Git URLs normalize WHATWG slashes and ASCII controls', () {
    for (final input in [
      ' https://example.test/repo.git\n',
      'https:example.test/repo.git',
      'https:/example.test/repo.git',
      r'https:\example.test\repo.git',
      'https://exa\tmple.test/re\npo.git',
    ]) {
      expect(withGitCredentials(input, 'user', 'pass'),
          'https://user:pass@example.test/repo.git');
      expect(deriveGitRepoDir(input), 'repo');
    }
  });

  test('config remote and credential fields preserve non-JS whitespace',
      () async {
    for (final code in [0x85, 0xfeff]) {
      final character = String.fromCharCode(code);
      final expected = code == 0x85 ? '${character}value$character' : 'value';
      final commands = RecordingCommands()
        ..stdout = '${character}value$character';
      final git = Git(commands);
      expect(await git.getConfig('key'), expected);
      expect(await git.remoteGet('/repo', 'origin'), expected);
      await git.dangerouslyAuthenticate(
          username: 'u',
          password: 'p',
          host: '${character}value$character',
          protocol: '${character}value$character');
      expect(commands.calls.last.positionalArguments.single,
          contains('protocol=$expected\nhost=$expected\n'));
    }
  });

  test('status and branch parsers use ECMAScript whitespace rules', () {
    for (final code in [
      9,
      10,
      11,
      12,
      13,
      32,
      160,
      5760,
      ...List.generate(11, (i) => 8192 + i),
      8232,
      8233,
      8239,
      8287,
      12288,
      65279,
    ]) {
      final whitespace = String.fromCharCode(code);
      // Newlines delimit porcelain records, so exercise them via branches.
      expect(
          parseGitBranches('${whitespace}main$whitespace').branches, ['main']);
      if (code != 10) {
        expect(parseGitStatus('## main [ahead ${whitespace}2]').ahead, 2);
      }
    }
    for (final code in [0x85, 0x180e, 0x200b]) {
      final character = String.fromCharCode(code);
      expect(parseGitBranches('${character}main$character').branches,
          ['${character}main$character']);
      expect(
          parseGitStatus('## main [ahead ${character}2]').ahead.isNaN, isTrue);
    }
  });

  test('tracking counters preserve upstream parseInt prefix and NaN behavior',
      () {
    for (final entry in {
      'ahead2, behind-3': [2, -3],
      'ahead +12suffix, behind 4.5': [12, 4],
      'gone': [0, 0],
      'ahead nope, behind': [double.nan, double.nan],
      'ahead 9007199254740993, behind 0x10': [9007199254740992.0, 0],
    }.entries) {
      final result = parseGitStatus('## main...origin/main [${entry.key}]');
      for (final pair in [
        [result.ahead, entry.value[0]],
        [result.behind, entry.value[1]],
      ]) {
        if (pair[1].isNaN) {
          expect(pair[0].isNaN, isTrue);
        } else {
          expect(pair[0], pair[1]);
        }
      }
    }
  });

  test('clone depth follows JavaScript number truthiness and formatting',
      () async {
    for (final entry in <num, String?>{
      0: null,
      double.nan: null,
      0.5: '0.5',
      -0.5: '-0.5',
      1.0: '1',
      1e21: '1e+21',
      double.infinity: 'Infinity',
      double.negativeInfinity: '-Infinity',
    }.entries) {
      final commands = RecordingCommands();
      await Git(commands)
          .clone('https://example.test/repo.git', depth: entry.key);
      final command =
          commands.calls.single.positionalArguments.single as String;
      if (entry.value == null) {
        expect(command, isNot(contains('--depth')));
      } else {
        expect(command, contains('--depth ${entry.value}'));
      }
    }
  });

  test('config scopes ignore repository paths outside local scope', () async {
    for (final scope in GitConfigScope.values) {
      final commands = RecordingCommands();
      final git = Git(commands);
      await git.setConfig('key', '', scope: scope, path: '/repo');
      final prefix = scope == GitConfigScope.local ? 'git -C /repo' : 'git';
      expect(commands.calls.last.positionalArguments.single,
          "$prefix config --${scope.value} key ''");
      commands.stdout = '  value \n';
      expect(await git.getConfig('key', scope: scope, path: '/repo'), 'value');
      expect(commands.calls.last.positionalArguments.single,
          '$prefix config --${scope.value} --get key || true');
      commands.stdout = ' \n';
      expect(await git.getConfig('key', scope: scope, path: '/repo'), isNull);
    }
  });

  test('configureUser and credential helper stop after first command failure',
      () async {
    const failure = CommandExitException(1, '', 'config failed');
    final commands = RecordingCommands()..replies.add(failure);
    await expectLater(
        Git(commands).configureUser('A', 'a@b'), throwsA(same(failure)));
    expect(commands.calls, hasLength(1));
    commands.calls.clear();
    commands.replies.add(failure);
    await expectLater(
        Git(commands).dangerouslyAuthenticate(username: 'u', password: 'p'),
        throwsA(same(failure)));
    expect(commands.calls, hasLength(1));
    commands.calls.clear();
    await Git(commands).dangerouslyAuthenticate(
        username: 'u',
        password: 'p',
        host: ' example.com ',
        protocol: ' http ');
    expect(commands.calls.last.positionalArguments.single,
        "printf %s 'protocol=http\nhost=example.com\nusername=u\npassword=p\n\n' | git credential approve");
    commands.calls.clear();
    await Git(commands).dangerouslyAuthenticate(
        username: 'u', password: 'p', host: '', protocol: '');
    expect(commands.calls.last.positionalArguments.single,
        "printf %s 'protocol=\nhost=\nusername=u\npassword=p\n\n' | git credential approve");
  });

  test('push and pull optional remote branch combinations match upstream',
      () async {
    for (final remote in <String?>[null, '', 'origin']) {
      for (final branch in <String?>[null, '', 'main']) {
        for (final upstream in [false, true]) {
          final commands = RecordingCommands();
          await Git(commands).push('/repo',
              remote: remote, branch: branch, setUpstream: upstream);
          expect(
              commands.calls.single.positionalArguments.single,
              [
                'git -C /repo push',
                if (upstream && remote == 'origin') '--set-upstream',
                if (remote == 'origin') 'origin',
                if (branch == 'main') 'main'
              ].join(' '));
        }
        final commands = RecordingCommands()..stdout = 'origin/main';
        await Git(commands).pull('/repo', remote: remote, branch: branch);
        expect(commands.calls.length,
            remote != 'origin' && branch != 'main' ? 2 : 1);
        expect(
            commands.calls.last.positionalArguments.single,
            [
              'git -C /repo pull',
              if (remote == 'origin') 'origin',
              if (branch == 'main') 'main'
            ].join(' '));
      }
    }
  });

  test('remote overwrite and fetch matrix preserves shell grouping', () async {
    for (final fetch in [false, true]) {
      for (final overwrite in [false, true]) {
        final commands = RecordingCommands();
        await Git(commands).remoteAdd(
            '/repo', 'origin', 'https://example.com/r',
            fetch: fetch, overwrite: overwrite);
        final add =
            'git -C /repo remote add ${fetch ? '-f ' : ''}origin https://example.com/r';
        final fallback =
            '$add || git -C /repo remote set-url origin https://example.com/r';
        expect(
            commands.calls.single.positionalArguments.single,
            !overwrite
                ? add
                : fetch
                    ? '($fallback) && git -C /repo fetch origin'
                    : fallback);
      }
    }
    final commands = RecordingCommands();
    for (final force in [false, true]) {
      await Git(commands).deleteBranch('/repo', 'topic', force: force);
      expect(commands.calls.last.positionalArguments.single,
          'git -C /repo branch ${force ? '-D' : '-d'} topic');
    }
  });

  test('clone optional branch depth and path match official truthiness',
      () async {
    for (final branch in <String?>[null, '', 'main']) {
      for (final depth in <int?>[null, 0, -1, 1]) {
        for (final path in <String?>[null, '', 'dest']) {
          final commands = RecordingCommands();
          await Git(commands).clone('https://example.com/r.git',
              branch: branch, depth: depth, path: path);
          expect(
              commands.calls.single.positionalArguments.single,
              [
                'git clone https://example.com/r.git',
                if (branch == 'main') '--branch main --single-branch',
                if (depth != null && depth != 0) '--depth $depth',
                if (path == 'dest') 'dest'
              ].join(' '));
        }
      }
    }
  });

  test('clone rejects explicit empty credential destination before execution',
      () async {
    final commands = RecordingCommands();
    await expectLater(
        Git(commands).clone('https://u:p@example.com/r.git', path: ''),
        throwsA(isA<InvalidArgumentException>().having(
            (e) => e.message,
            'message',
            'A destination path is required when using credentials without storing them.')));
    expect(commands.calls, isEmpty);
    const cloneError = CommandExitException(1, '', 'clone failed');
    commands.replies.add(cloneError);
    await expectLater(Git(commands).clone('https://u:p@example.com/r.git'),
        throwsA(same(cloneError)));
    expect(commands.calls, hasLength(1));
    commands.calls.clear();
    const cleanupError = CommandExitException(1, '', 'cleanup failed');
    commands.replies.addAll([
      const CommandResult(exitCode: 0, stdout: 'cloned', stderr: ''),
      cleanupError,
    ]);
    await expectLater(Git(commands).clone('https://u:p@example.com/r.git'),
        throwsA(same(cleanupError)));
    expect(commands.calls, hasLength(2));
    expect(commands.calls.last.positionalArguments.single,
        'git -C r remote set-url origin https://example.com/r.git');
  });

  test('init and commit optional flags preserve official ordering', () async {
    final commands = RecordingCommands();
    final git = Git(commands);
    for (final bare in [false, true]) {
      for (final branch in <String?>[null, '', 'main']) {
        await git.init('/repo', bare: bare, initialBranch: branch);
        expect(
            commands.calls.last.positionalArguments.single,
            [
              'git init',
              if (branch == 'main') '--initial-branch main',
              if (bare) '--bare',
              '/repo'
            ].join(' '));
      }
    }
    for (final name in <String?>[null, '', 'Alice']) {
      for (final email in <String?>[null, '', 'alice@example.com']) {
        for (final empty in [false, true]) {
          await git.commit('/repo', 'message',
              authorName: name, authorEmail: email, allowEmpty: empty);
          expect(
              commands.calls.last.positionalArguments.single,
              [
                'git -C /repo',
                if (name == 'Alice') '-c user.name=Alice',
                if (email == 'alice@example.com')
                  '-c user.email=alice@example.com',
                'commit -m message',
                if (empty) '--allow-empty'
              ].join(' '));
        }
      }
    }
  });

  test('add distinguishes omitted empty and explicit paths for either all flag',
      () async {
    final commands = RecordingCommands();
    final git = Git(commands);
    await git.add('/repo');
    expect(
        commands.calls.last.positionalArguments.single, 'git -C /repo add -A');
    for (final all in [false, true]) {
      for (final files in <List<String>?>[
        null,
        [],
        ['a b', '-f']
      ]) {
        await git.add('/repo', all: all, files: files);
        expect(
            commands.calls.last.positionalArguments.single,
            files == null || files.isEmpty
                ? 'git -C /repo add ${all ? '-A' : '.'}'
                : "git -C /repo add -- 'a b' -f");
      }
    }
  });

  test('restore nullable option matrix preserves official default rules',
      () async {
    for (final staged in <bool?>[null, false, true]) {
      for (final worktree in <bool?>[null, false, true]) {
        final commands = RecordingCommands();
        final git = Git(commands);
        final rejected = worktree == false && staged != true;
        if (rejected) {
          expect(
              () => git.restore('/repo',
                  paths: ['a'], staged: staged, worktree: worktree),
              throwsA(isA<InvalidArgumentException>().having(
                  (e) => e.message,
                  'message',
                  'At least one of staged or worktree must be true.')));
          expect(commands.calls, isEmpty);
          continue;
        }
        await git.restore('/repo',
            paths: ['a'], staged: staged, worktree: worktree, source: '');
        final flags = [
          if (worktree == true || (worktree == null && staged == null))
            '--worktree',
          if (staged == true) '--staged',
        ];
        expect(commands.calls.single.positionalArguments.first,
            ['git -C /repo restore', ...flags, '-- a'].join(' '));
      }
    }
    final commands = RecordingCommands();
    expect(
        () => Git(commands).restore('/repo', paths: []),
        throwsA(isA<InvalidArgumentException>().having(
            (e) => e.message, 'message', 'At least one path is required.')));
    expect(commands.calls, isEmpty);
  });

  test('reset modes and optional arguments match the official command builder',
      () async {
    final commands = RecordingCommands();
    final git = Git(commands);
    await git.reset('/repo');
    expect(commands.calls.last.positionalArguments.first, 'git -C /repo reset');
    await git.reset('/repo', mode: '', target: '');
    expect(commands.calls.last.positionalArguments.first, 'git -C /repo reset');
    for (final mode in ['soft', 'mixed', 'hard', 'merge', 'keep']) {
      await git.reset('/repo', mode: mode, target: 'HEAD~1', paths: ['a b']);
      expect(commands.calls.last.positionalArguments.first,
          "git -C /repo reset --$mode 'HEAD~1' -- 'a b'");
    }
    final count = commands.calls.length;
    expect(
        () => git.reset('/repo', mode: 'invalid'),
        throwsA(isA<InvalidArgumentException>().having(
            (e) => e.message,
            'message',
            'Reset mode must be one of soft, mixed, hard, merge, keep.')));
    expect(commands.calls, hasLength(count));
  });

  CommandResult result(String out) =>
      CommandResult(pid: 1, exitCode: 0, stdout: out, stderr: '');
  test(
      'restore-only failure propagates and ambiguous remote rejects before mutation',
      () async {
    const restoreError = CommandExitException(1, '', 'restore failed');
    final commands = RecordingCommands()
      ..replies.addAll([
        result('https://example.com/r'),
        result(''),
        result('pushed'),
        restoreError,
      ]);
    await expectLater(
        Git(commands)
            .push('/repo', remote: 'origin', username: 'u', password: 'p'),
        throwsA(same(restoreError)));
    commands.calls.clear();
    commands.replies.add(result('origin\nbackup\n'));
    await expectLater(Git(commands).push('/repo', username: 'u', password: 'p'),
        throwsA(isA<InvalidArgumentException>()));
    expect(commands.calls.length, 1);
    await expectLater(
        Git(commands).clone('https://example.com/r', password: 'p'),
        throwsA(isA<InvalidArgumentException>()));
    expect(commands.calls.length, 1);
  });
  test('Git URL credential encoding and stripping match WHATWG examples', () {
    expect(
        withGitCredentials(
            'https://EXAMPLE.com:443/a%20b.git', 'ü!\$&+,%', '[]^|;='),
        'https://%C3%BC!\$&+,%:%5B%5D%5E%7C%3B%3D@example.com/a%20b.git');
    expect(deriveGitRepoDir('https://example.com/a%2Fb.git'), 'a%2Fb');
    expect(
        withGitCredentials('https://example.com:443/repo.git', 'a@b', 'p:/?#'),
        'https://a%40b:p%3A%2F%3F%23@example.com/repo.git');
    expect(withGitCredentials('https://example.com', 'a+b', r'p$&,'),
        r'https://a+b:p$&,@example.com/');
    expect(stripGitCredentials('https://a:p@example.com/repo'),
        'https://example.com/repo');
    expect(stripGitCredentials('git@example.com:repo.git'),
        'git@example.com:repo.git');
    expect(deriveGitRepoDir('https://example.com/a/repo.git///'), 'repo');
    expect(() => withGitCredentials('ssh://example.com/repo', 'a', 'p'),
        throwsA(isA<InvalidArgumentException>()));
  });
  test('clone removes inline credentials from derived destination', () async {
    final commands = RecordingCommands();
    await Git(commands).clone('https://example.com/repo.git',
        username: 'u', password: 'p', branch: 'main', depth: 1);
    expect(commands.calls[0].positionalArguments.single,
        'git clone https://u:p@example.com/repo.git --branch main --single-branch --depth 1 repo');
    expect(commands.calls[1].positionalArguments.single,
        'git -C repo remote set-url origin https://example.com/repo.git');
    commands.calls.clear();
    await Git(commands).clone('https://u:p@example.com/r.git',
        dangerouslyStoreCredentials: true);
    expect(commands.calls.length, 1);
  });
  test('push restores remote on success and forwards the official arguments',
      () async {
    final commands = RecordingCommands()
      ..replies.addAll([
        result('origin\n'),
        result('https://example.com/r.git\n'),
        result(''),
        result('pushed'),
        result('')
      ]);
    final pushed = await Git(commands)
        .push('/repo', username: 'u', password: 'p', branch: 'main');
    expect(pushed.stdout, 'pushed');
    expect(commands.calls[3].positionalArguments.single,
        'git -C /repo push --set-upstream origin main');
    expect(commands.calls.last.positionalArguments.single,
        'git -C /repo remote set-url origin https://example.com/r.git');
  });
  test('credential operation error wins over restore error and is not remapped',
      () async {
    const operationError =
        CommandExitException(128, '', 'Authentication failed');
    const restoreError = CommandExitException(1, '', 'restore failed');
    final commands = RecordingCommands()
      ..replies.addAll([
        result('https://example.com/r'),
        result(''),
        operationError,
        restoreError
      ]);
    await expectLater(
        Git(commands)
            .pull('/repo', remote: 'origin', username: 'u', password: 'p'),
        throwsA(same(operationError)));
    expect(commands.calls.last.positionalArguments.single,
        'git -C /repo remote set-url origin https://example.com/r');
  });
  test('authentication and missing upstream map only uncredentialed operations',
      () async {
    final commands = RecordingCommands()
      ..replies
          .add(const CommandExitException(128, '', 'Authentication failed'));
    await expectLater(
        Git(commands).clone('https://example.com/r', username: 'u'),
        throwsA(isA<GitAuthException>()
            .having((e) => e.message, 'message', contains('password/token'))));
    commands.replies
        .add(const CommandExitException(128, '', 'has no upstream branch'));
    await expectLater(
        Git(commands).push('/repo'), throwsA(isA<GitUpstreamException>()));
    commands.replies.add(const CommandExitException(128, '', 'no upstream'));
    await expectLater(
        Git(commands).pull('/repo'), throwsA(isA<GitUpstreamException>()));
    expect(commands.calls.last.positionalArguments.single,
        "git -C /repo rev-parse --abbrev-ref --symbolic-full-name '@{u}'");
  });

  test('config scopes and credential helper preserve official sequencing',
      () async {
    final commands = RecordingCommands();
    final git = Git(commands);
    await git.configureUser('A B', 'a@b',
        scope: GitConfigScope.local, path: '/repo');
    expect(commands.calls[0].positionalArguments.single,
        "git -C /repo config --local user.name 'A B'");
    expect(commands.calls[1].positionalArguments.single,
        'git -C /repo config --local user.email a@b');
    await expectLater(git.getConfig('user.name', scope: GitConfigScope.local),
        throwsA(isA<InvalidArgumentException>()));
    commands.stdout = ' value\n';
    expect(await git.getConfig('key'), 'value');
    await git.dangerouslyAuthenticate(username: 'user', password: "t'oken");
    expect(commands.calls[commands.calls.length - 2].positionalArguments.single,
        'git config --global credential.helper store');
    expect(commands.calls.last.positionalArguments.single,
        "printf %s 'protocol=https\nhost=github.com\nusername=user\npassword=t'\"'\"'oken\n\n' | git credential approve");
  });
  test('porcelain status preserves upstream priority and counts', () {
    final status = parseGitStatus(
        '## main...origin/main [ahead 2, behind 3]\r\n'
        'MM both.txt\n R old -> new -> name\n?? "a b"\nUU conflict\n D deleted\n');
    expect(status.currentBranch, 'main');
    expect(status.upstream, 'origin/main');
    expect([status.ahead, status.behind], [2, 3]);
    expect(status.totalCount, 5);
    expect(status.stagedCount, 2);
    expect(status.unstagedCount, 3);
    expect(status.untrackedCount, 1);
    expect(status.conflictCount, 1);
    expect(status.fileStatus[1].renamedFrom, 'old');
    expect(status.fileStatus[1].name, 'new -> name');
    expect(status.fileStatus[2].name, '"a b"');
    expect(
        status.hasChanges && status.hasConflicts && status.hasStaged, isTrue);
  });
  test('initial and detached branches follow official normalization', () {
    expect(parseGitStatus('## No commits yet on main\n').currentBranch, 'main');
    expect(
        parseGitStatus('## Initial commit on topic\n').currentBranch, 'topic');
    expect(parseGitStatus('## HEAD (detached at abc)\n').detached, isTrue);
    expect(parseGitStatus('## HEAD (no branch)\n').currentBranch, isNull);
    expect(parseGitStatus('').isClean, isTrue);
    // Retain the fixed upstream behavior when callers omit -b.
    expect(parseGitStatus(' M first\n M second\n').totalCount, 1);
  });
  test('branch parser and shell command quoting match upstream', () {
    final branches = parseGitBranches('main\t*\r\nfeature\t \n');
    expect(branches.branches, ['main', 'feature']);
    expect(branches.currentBranch, 'main');
    expect(buildGitCommand(['commit', '-m', "a'b"], '/tmp/a b'),
        "git -C '/tmp/a b' commit -m 'a'\"'\"'b'");
  });
  test('facade forwards environment and constructs overwrite and restore',
      () async {
    final commands = RecordingCommands();
    final git = Git(commands);
    await git.remoteAdd('/repo', 'origin', 'https://example.com/r',
        fetch: true,
        overwrite: true,
        options: const GitRequestOptions(
            user: 'root', envs: {'GIT_TERMINAL_PROMPT': '1'}));
    expect(commands.calls.last.positionalArguments.single,
        '(git -C /repo remote add -f origin https://example.com/r || git -C /repo remote set-url origin https://example.com/r) && git -C /repo fetch origin');
    expect(commands.calls.last.namedArguments[#envs],
        {'GIT_TERMINAL_PROMPT': '1'});
    await git.restore('/repo', paths: ['-danger'], staged: true);
    expect(commands.calls.last.positionalArguments.single,
        'git -C /repo restore --staged -- -danger');
    await git.add('/repo', files: ['a b']);
    expect(commands.calls.last.positionalArguments.single,
        "git -C /repo add -- 'a b'");
    await git.commit('/repo', 'message',
        authorName: 'A', authorEmail: 'a@b', allowEmpty: true);
    expect(commands.calls.last.positionalArguments.single,
        'git -C /repo -c user.name=A -c user.email=a@b commit -m message --allow-empty');
    expect(() => git.reset('/repo', mode: 'invalid'),
        throwsA(isA<InvalidArgumentException>()));
    expect(
        () =>
            git.restore('/repo', paths: ['.'], staged: false, worktree: false),
        throwsA(isA<InvalidArgumentException>()));
  });
}
