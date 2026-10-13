import 'commands.dart';
import 'js_number.dart';
import 'js_string.dart';
import 'js_ipv4.dart';
import 'connection.dart';
import 'errors.dart';
import 'models.dart';
import 'template.dart' show shellQuote;

/// Compatibility types for the deprecated official Git module.
enum GitConfigScope {
  global,
  local,
  system;

  String get value => name;
  String toJson() => value;
}

/// Reset mode wire values: soft, mixed, hard, merge, or keep.
typedef GitResetMode = String;

enum GitStatusLabel {
  conflict,
  renamed,
  copied,
  deleted,
  added,
  modified,
  typechange,
  untracked,
  unknown;

  String get value => name;
  String toJson() => value;
}

class GitFileStatus {
  final String name;
  final GitStatusLabel status;
  final String indexStatus;
  final String workingTreeStatus;
  final bool staged;
  final String? renamedFrom;
  const GitFileStatus(
      {required this.name,
      required this.status,
      required this.indexStatus,
      required this.workingTreeStatus,
      required this.staged,
      this.renamedFrom});
}

class GitStatus {
  final String? currentBranch;
  final String? upstream;
  final num ahead;
  final num behind;
  final bool detached;
  final List<GitFileStatus> fileStatus;
  GitStatus(
      {this.currentBranch,
      this.upstream,
      this.ahead = 0,
      this.behind = 0,
      this.detached = false,
      Iterable<GitFileStatus> fileStatus = const []})
      : fileStatus = List.unmodifiable(fileStatus);
  bool get isClean => fileStatus.isEmpty;
  bool get hasChanges => !isClean;
  bool get hasStaged => stagedCount > 0;
  bool get hasUntracked => untrackedCount > 0;
  bool get hasConflicts => conflictCount > 0;
  int get totalCount => fileStatus.length;
  int get stagedCount => fileStatus.where((f) => f.staged).length;
  // Upstream counts entries without index changes, including untracked files.
  int get unstagedCount => totalCount - stagedCount;
  int get untrackedCount =>
      fileStatus.where((f) => f.status == GitStatusLabel.untracked).length;
  int get conflictCount =>
      fileStatus.where((f) => f.status == GitStatusLabel.conflict).length;
}

class GitBranches {
  final List<String> branches;
  final String? currentBranch;
  GitBranches(Iterable<String> branches, {this.currentBranch})
      : branches = List.unmodifiable(branches);
}

/// Parse the fixed upstream porcelain-v1 format, retaining quoted filenames.
GitStatus parseGitStatus(String output) {
  final lines = output
      .split('\n')
      .map((l) => l.replaceFirst(RegExp(r'\r$'), ''))
      .where((l) => jsTrim(l).isNotEmpty)
      .toList();
  String? branch, upstream;
  num ahead = 0, behind = 0;
  var detached = false;
  if (lines.isNotEmpty && lines.first.startsWith('## ')) {
    final info = lines.first.substring(3);
    final offset = info.indexOf(' [');
    final raw = offset < 0 ? info : info.substring(0, offset);
    final tracking =
        offset < 0 ? '' : info.substring(offset + 2, info.length - 1);
    var normalized = raw;
    if (raw.startsWith('HEAD (detached at ')) {
      normalized = raw
          .replaceFirst('HEAD (detached at ', '')
          .replaceFirst(RegExp(r'\)$'), '');
    } else {
      normalized = raw
          .replaceFirst('HEAD (no branch)', 'HEAD')
          .replaceFirst('No commits yet on ', '')
          .replaceFirst('Initial commit on ', '');
    }
    detached = raw.startsWith('HEAD (detached at ') ||
        raw.contains('detached') ||
        normalized.startsWith('HEAD');
    if (!detached) {
      final parts = normalized.split('...');
      branch = parts.first.isEmpty ? null : parts.first;
      if (parts.length > 1) upstream = parts[1].isEmpty ? null : parts[1];
    }
    num count(String name) {
      if (!tracking.contains(name)) return 0;
      final text = jsTrim(tracking.split(name)[1].split(',').first);
      final digits = RegExp(r'^[+-]?[0-9]+').firstMatch(text)?.group(0);
      return digits == null ? double.nan : double.parse(digits);
    }

    ahead = count('ahead');
    behind = count('behind');
  }
  final files = <GitFileStatus>[];
  // The official parser skips the first line even when no branch header exists.
  for (final line in lines.skip(1)) {
    if (line.startsWith('?? ')) {
      files.add(GitFileStatus(
          name: line.substring(3),
          status: GitStatusLabel.untracked,
          indexStatus: '?',
          workingTreeStatus: '?',
          staged: false));
      continue;
    }
    if (line.length < 3) continue;
    final index = line[0], working = line[1];
    final path = line.substring(3);
    final parts = path.split(' -> ');
    final symbols = {index, working};
    final priorities = {
      'U': GitStatusLabel.conflict,
      'R': GitStatusLabel.renamed,
      'C': GitStatusLabel.copied,
      'D': GitStatusLabel.deleted,
      'A': GitStatusLabel.added,
      'M': GitStatusLabel.modified,
      'T': GitStatusLabel.typechange,
      '?': GitStatusLabel.untracked
    };
    final status = priorities.entries
            .where((e) => symbols.contains(e.key))
            .map((e) => e.value)
            .firstOrNull ??
        GitStatusLabel.unknown;
    files.add(GitFileStatus(
        name: parts.length > 1 ? parts.skip(1).join(' -> ') : path,
        renamedFrom:
            parts.length > 1 && parts.first.isNotEmpty ? parts.first : null,
        status: status,
        indexStatus: index,
        workingTreeStatus: working,
        staged: index != ' ' && index != '?'));
  }
  return GitStatus(
      currentBranch: branch,
      upstream: upstream,
      ahead: ahead,
      behind: behind,
      detached: detached,
      fileStatus: files);
}

GitBranches parseGitBranches(String output) {
  final names = <String>[];
  String? current;
  for (final line
      in output.split('\n').map(jsTrim).where((l) => l.isNotEmpty)) {
    final parts = line.split('\t');
    names.add(parts.first);
    if (parts.length > 1 && parts[1] == '*') current = parts.first;
  }
  return GitBranches(names, currentBranch: current);
}

class GitRequestOptions {
  final String? cwd;
  final String? user;
  final Map<String, String> envs;
  final Duration timeout;
  final RequestOptions? requestOptions;
  const GitRequestOptions(
      {this.requestOptions,
      this.cwd,
      this.user,
      this.envs = const {},
      this.timeout = const Duration(seconds: 60)});
}

String buildGitCommand(List<String> args, [String? repoPath]) => [
      'git',
      if (repoPath != null && repoPath.isNotEmpty) ...['-C', repoPath],
      ...args
    ].map(shellQuote).join(' ');

Uri _gitUri(String url) {
  // WHATWG removes ASCII tabs/newlines globally and surrounding C0 spaces.
  var normalized = url
      .replaceAll(RegExp(r'[\u0009\u000A\u000D]'), '')
      .replaceFirst(RegExp(r'^[\u0000-\u0020]+'), '')
      .replaceFirst(RegExp(r'[\u0000-\u0020]+$'), '');
  final special =
      RegExp(r'^https?:', caseSensitive: false).firstMatch(normalized);
  if (special != null) {
    final suffix = normalized.substring(special.end);
    final boundary = suffix.indexOf(RegExp(r'[?#]'));
    final authorityPath =
        (boundary < 0 ? suffix : suffix.substring(0, boundary))
            .replaceAll(r'\', '/')
            .replaceFirst(RegExp(r'^/+'), '');
    normalized = '${normalized.substring(0, special.end)}//$authorityPath'
        '${boundary < 0 ? '' : suffix.substring(boundary)}';
  }
  final parsed = Uri.tryParse(normalized);
  if (parsed == null ||
      !parsed.hasScheme ||
      ((parsed.scheme == 'http' || parsed.scheme == 'https') &&
          parsed.host.isEmpty)) {
    throw InvalidArgumentException('Invalid Git URL: $url');
  }
  if (parsed.scheme == 'http' || parsed.scheme == 'https') {
    try {
      final host = Uri.decodeComponent(parsed.host);
      if (!parsed.authority.split('@').last.startsWith('[') &&
          RegExp(r'[\u0000-\u0020\u007F#%/:<>?@\[\]\\^|]').hasMatch(host)) {
        throw const FormatException('Invalid special host');
      }
      return parsed.replace(host: jsIpv4Host(host));
    } on FormatException {
      throw InvalidArgumentException('Invalid Git URL: $url');
    }
  }
  return parsed;
}

String _credentialPart(String text) => Uri.encodeComponent(text)
    .replaceAll('%24', r'$')
    .replaceAll('%26', '&')
    .replaceAll('%2B', '+')
    .replaceAll('%2C', ',');
String _httpUrl(Uri uri) {
  // WHATWG URL inserts a root path and omits default HTTP ports.
  return uri.replace(path: uri.path.isEmpty ? '/' : uri.path).toString();
}

String withGitCredentials(String url, String? username, String? password) {
  if ((username == null || username.isEmpty) &&
      (password == null || password.isEmpty)) {
    return url;
  }
  if (username == null ||
      username.isEmpty ||
      password == null ||
      password.isEmpty) {
    throw const InvalidArgumentException(
        'Both username and password are required when using Git credentials.');
  }
  final parsed = _gitUri(url);
  if (parsed.scheme != 'http' && parsed.scheme != 'https') {
    throw const InvalidArgumentException(
        'Only http(s) Git URLs support username/password credentials.');
  }
  final base = _httpUrl(parsed.replace(userInfo: ''));
  final credentials =
      '${_credentialPart(username)}:${_credentialPart(password)}'
          .replaceAll('%25', '%');
  return base.replaceFirst('://', '://$credentials@');
}

String stripGitCredentials(String url) {
  try {
    final parsed = _gitUri(url);
    if ((parsed.scheme != 'http' && parsed.scheme != 'https') ||
        parsed.userInfo.isEmpty) {
      return url;
    }
    return _httpUrl(parsed.replace(userInfo: ''));
  } on InvalidArgumentException {
    return url;
  }
}

String? deriveGitRepoDir(String url) {
  try {
    final serialized = _gitUri(url).toString();
    final path = RegExp(r'^[^:]+:(?://[^/?#]*)?([^?#]*)')
        .firstMatch(serialized)!
        .group(1)!
        .replaceFirst(RegExp(r'/+$'), '');
    final name = path.split('/').last;
    if (name.isEmpty) return null;
    return name.endsWith('.git') ? name.substring(0, name.length - 4) : name;
  } on InvalidArgumentException {
    return null;
  }
}

bool _gitFailure(Object error, List<String> snippets) {
  if (error is! CommandExitException) return false;
  final text = '${error.stderr}\n${error.stdout}'.toLowerCase();
  return snippets.any(text.contains);
}

bool _authFailure(Object error) => _gitFailure(error, [
      'authentication failed',
      'terminal prompts disabled',
      'could not read username',
      'invalid username or password',
      'access denied',
      'permission denied',
      'not authorized'
    ]);
bool _missingUpstream(Object error) => _gitFailure(error, [
      'has no upstream branch',
      'no upstream branch',
      'no upstream configured',
      'no tracking information for the current branch',
      'no tracking information',
      'set the remote as upstream',
      'set the upstream branch',
      'please specify which branch you want to merge with'
    ]);
String _authMessage(String action, bool missingPassword) => missingPassword
    ? 'Git $action requires a password/token for private repositories.'
    : 'Git $action requires credentials for private repositories.';
String _upstreamMessage(String action) => action == 'push'
    ? 'Git push failed because no upstream branch is configured. Set upstream once with { setUpstream: true } (and optional remote/branch), or pass remote and branch explicitly.'
    : 'Git pull failed because no upstream branch is configured. Pass remote and branch explicitly, or set upstream once (push with { setUpstream: true } or run: git branch --set-upstream-to=origin/<branch> <branch>).';

/// Compatibility facade for the deprecated JS Git module.
class Git {
  final Commands _commands;
  Git(this._commands);
  Future<CommandResult> _shell(String command, GitRequestOptions? options) =>
      _commands.run(command,
          options: options?.requestOptions,
          cwd: options?.cwd,
          user: options?.user,
          envs: {'GIT_TERMINAL_PROMPT': '0', ...?options?.envs},
          timeout: options?.timeout ?? const Duration(seconds: 60));
  Future<CommandResult> _run(
          List<String> args, String? path, GitRequestOptions? options) =>
      _shell(buildGitCommand(args, path), options);

  Future<CommandResult> init(String path,
          {bool bare = false,
          String? initialBranch,
          GitRequestOptions? options}) =>
      _run([
        'init',
        if (initialBranch != null && initialBranch.isNotEmpty) ...[
          '--initial-branch',
          initialBranch
        ],
        if (bare) '--bare',
        path
      ], null, options);
  Future<CommandResult> remoteAdd(String path, String name, String url,
      {bool fetch = false,
      bool overwrite = false,
      GitRequestOptions? options}) {
    if (name.isEmpty || url.isEmpty) {
      throw const InvalidArgumentException(
          'Both remote name and URL are required to add a git remote.');
    }
    final args = ['remote', 'add', if (fetch) '-f', name, url];
    if (!overwrite) return _run(args, path, options);
    var command = '${buildGitCommand(args, path)} || ${buildGitCommand([
          'remote',
          'set-url',
          name,
          url
        ], path)}';
    if (fetch) {
      command = '($command) && ${buildGitCommand(['fetch', name], path)}';
    }
    return _shell(command, options);
  }

  Future<String?> remoteGet(String path, String name,
      {GitRequestOptions? options}) async {
    if (name.isEmpty) {
      throw const InvalidArgumentException('Remote name is required.');
    }
    final result = await _shell(
        '${buildGitCommand(['remote', 'get-url', name], path)} || true',
        options);
    return jsTrim(result.stdout).isEmpty ? null : jsTrim(result.stdout);
  }

  Future<GitStatus> status(String path, {GitRequestOptions? options}) async =>
      parseGitStatus(
          (await _run(['status', '--porcelain=1', '-b'], path, options))
              .stdout);
  Future<GitBranches> branches(String path,
          {GitRequestOptions? options}) async =>
      parseGitBranches((await _run(
              ['branch', '--format=%(refname:short)\t%(HEAD)'], path, options))
          .stdout);
  Future<CommandResult> createBranch(String path, String branch,
          {GitRequestOptions? options}) =>
      _run(['checkout', '-b', branch], path, options);
  Future<CommandResult> checkoutBranch(String path, String branch,
          {GitRequestOptions? options}) =>
      _run(['checkout', branch], path, options);
  Future<CommandResult> deleteBranch(String path, String branch,
          {bool force = false, GitRequestOptions? options}) =>
      _run(['branch', force ? '-D' : '-d', branch], path, options);
  Future<CommandResult> add(String path,
          {List<String>? files, bool all = true, GitRequestOptions? options}) =>
      _run([
        'add',
        if (files == null || files.isEmpty)
          all ? '-A' : '.'
        else ...['--', ...files]
      ], path, options);
  Future<CommandResult> commit(String path, String message,
          {String? authorName,
          String? authorEmail,
          bool allowEmpty = false,
          GitRequestOptions? options}) =>
      _run([
        if (authorName != null && authorName.isNotEmpty) ...[
          '-c',
          'user.name=$authorName'
        ],
        if (authorEmail != null && authorEmail.isNotEmpty) ...[
          '-c',
          'user.email=$authorEmail'
        ],
        'commit',
        '-m',
        message,
        if (allowEmpty) '--allow-empty'
      ], path, options);
  Future<CommandResult> reset(String path,
      {GitResetMode? mode,
      String? target,
      List<String> paths = const [],
      GitRequestOptions? options}) {
    if (mode != null &&
        mode.isNotEmpty &&
        !['soft', 'mixed', 'hard', 'merge', 'keep'].contains(mode)) {
      throw const InvalidArgumentException(
          'Reset mode must be one of soft, mixed, hard, merge, keep.');
    }
    return _run([
      'reset',
      if (mode != null && mode.isNotEmpty) '--$mode',
      if (target != null && target.isNotEmpty) target,
      if (paths.isNotEmpty) ...['--', ...paths]
    ], path, options);
  }

  Future<CommandResult> restore(String path,
      {required List<String> paths,
      bool? staged,
      bool? worktree,
      String? source,
      GitRequestOptions? options}) {
    if (paths.isEmpty) {
      throw const InvalidArgumentException('At least one path is required.');
    }
    var resolvedStaged = staged, resolvedWorktree = worktree;
    if (staged == null && worktree == null) {
      resolvedWorktree = true;
    } else if (staged == true && worktree == null) {
      resolvedWorktree = false;
    } else if (staged == null && worktree != null) {
      resolvedStaged = false;
    }
    if (resolvedStaged == false && resolvedWorktree == false) {
      throw const InvalidArgumentException(
          'At least one of staged or worktree must be true.');
    }
    return _run([
      'restore',
      if (resolvedWorktree == true) '--worktree',
      if (resolvedStaged == true) '--staged',
      if (source != null && source.isNotEmpty) ...['--source', source],
      '--',
      ...paths
    ], path, options);
  }

  String? _configPath(GitConfigScope scope, String? path) {
    if (scope != GitConfigScope.local) return null;
    if (path == null || path.isEmpty) {
      throw const InvalidArgumentException(
          'A repository path is required when using scope "local".');
    }
    return path;
  }

  Future<CommandResult> setConfig(String key, String value,
      {GitConfigScope scope = GitConfigScope.global,
      String? path,
      GitRequestOptions? options}) {
    if (key.isEmpty) {
      throw const InvalidArgumentException('Git config key is required.');
    }
    return _run(['config', '--${scope.name}', key, value],
        _configPath(scope, path), options);
  }

  Future<String?> getConfig(String key,
      {GitConfigScope scope = GitConfigScope.global,
      String? path,
      GitRequestOptions? options}) async {
    if (key.isEmpty) {
      throw const InvalidArgumentException('Git config key is required.');
    }
    final result = await _shell(
        '${buildGitCommand([
              'config',
              '--${scope.name}',
              '--get',
              key
            ], _configPath(scope, path))} || true',
        options);
    return jsTrim(result.stdout).isEmpty ? null : jsTrim(result.stdout);
  }

  Future<CommandResult> configureUser(String name, String email,
      {GitConfigScope scope = GitConfigScope.global,
      String? path,
      GitRequestOptions? options}) async {
    if (name.isEmpty || email.isEmpty) {
      throw const InvalidArgumentException('Both name and email are required.');
    }
    await setConfig('user.name', name,
        scope: scope, path: path, options: options);
    return setConfig('user.email', email,
        scope: scope, path: path, options: options);
  }

  Future<CommandResult> dangerouslyAuthenticate(
      {required String username,
      required String password,
      String host = 'github.com',
      String protocol = 'https',
      GitRequestOptions? options}) async {
    if (username.isEmpty || password.isEmpty) {
      throw const InvalidArgumentException(
          'Both username and password are required to authenticate git.');
    }
    final input = [
      'protocol=${jsTrim(protocol)}',
      'host=${jsTrim(host)}',
      'username=$username',
      'password=$password',
      '',
      ''
    ].join('\n');
    await _run(
        ['config', '--global', 'credential.helper', 'store'], null, options);
    return _shell(
        'printf %s ${shellQuote(input)} | ${buildGitCommand([
              'credential',
              'approve'
            ])}',
        options);
  }

  Future<CommandResult> clone(String url,
      {String? path,
      String? branch,
      num? depth,
      String? username,
      String? password,
      bool dangerouslyStoreCredentials = false,
      GitRequestOptions? options}) async {
    if (password != null &&
        password.isNotEmpty &&
        (username == null || username.isEmpty)) {
      throw const InvalidArgumentException(
          'Username is required when using a password or token for git clone.');
    }
    try {
      final authUrl = username != null &&
              username.isNotEmpty &&
              password != null &&
              password.isNotEmpty
          ? withGitCredentials(url, username, password)
          : url;
      final sanitized = stripGitCredentials(authUrl);
      final strip = !dangerouslyStoreCredentials && sanitized != authUrl;
      final repo = strip ? path ?? deriveGitRepoDir(url) : path;
      if (strip && (repo == null || repo.isEmpty)) {
        throw const InvalidArgumentException(
            'A destination path is required when using credentials without storing them.');
      }
      final result = await _run([
        'clone',
        authUrl,
        if (branch != null && branch.isNotEmpty) ...[
          '--branch',
          branch,
          '--single-branch'
        ],
        if (depth != null && depth != 0 && !depth.isNaN) ...[
          '--depth',
          jsNumberString(depth)
        ],
        if (repo != null && repo.isNotEmpty) repo
      ], null, options);
      if (strip) {
        await _run(['remote', 'set-url', 'origin', sanitized], repo, options);
      }
      return result;
    } catch (error) {
      if (_authFailure(error)) {
        throw GitAuthException(_authMessage(
            'clone',
            username != null &&
                username.isNotEmpty &&
                (password == null || password.isEmpty)));
      }
      rethrow;
    }
  }

  Future<String> _resolveRemote(
      String path, String? remote, GitRequestOptions? options) async {
    if (remote != null && remote.isNotEmpty) return remote;
    final result = await _run(['remote'], path, options);
    final remotes = result.stdout
        .split('\n')
        .map(jsTrim)
        .where((s) => s.isNotEmpty)
        .toList();
    if (remotes.length == 1) return remotes.single;
    throw const InvalidArgumentException(
        'Remote is required when using username/password and the repository has multiple remotes.');
  }

  Future<CommandResult> _withCredentials(
      String path,
      String remote,
      String username,
      String password,
      GitRequestOptions? options,
      Future<CommandResult> Function() operation) async {
    final original = jsTrim(
        (await _run(['remote', 'get-url', remote], path, options)).stdout);
    if (original.isEmpty) {
      throw InvalidArgumentException(
          'Remote "$remote" URL not found in repository.');
    }
    final auth = withGitCredentials(original, username, password);
    await _run(['remote', 'set-url', remote, auth], path, options);
    CommandResult? result;
    Object? operationError;
    StackTrace? operationStack;
    try {
      result = await operation();
    } catch (error, stack) {
      operationError = error;
      operationStack = stack;
    }
    try {
      await _run(['remote', 'set-url', remote, original], path, options);
    } catch (_) {
      if (operationError == null) rethrow;
    }
    if (operationError != null) {
      Error.throwWithStackTrace(operationError, operationStack!);
    }
    return result!;
  }

  Future<CommandResult> push(String path,
      {String? remote,
      String? branch,
      bool setUpstream = true,
      String? username,
      String? password,
      GitRequestOptions? options}) async {
    if (password != null &&
        password.isNotEmpty &&
        (username == null || username.isEmpty)) {
      throw const InvalidArgumentException(
          'Username is required when using a password or token for git push.');
    }
    List<String> args(String? resolved) {
      final target = resolved ?? remote;
      return [
        'push',
        if (setUpstream && target != null && target.isNotEmpty)
          '--set-upstream',
        if (target != null && target.isNotEmpty) target,
        if (branch != null && branch.isNotEmpty) branch
      ];
    }

    if (username != null &&
        username.isNotEmpty &&
        password != null &&
        password.isNotEmpty) {
      final target = await _resolveRemote(path, remote, options);
      return _withCredentials(path, target, username, password, options,
          () => _run(args(target), path, options));
    }
    try {
      return await _run(args(null), path, options);
    } catch (error) {
      if (_authFailure(error)) {
        throw GitAuthException(_authMessage(
            'push',
            username != null &&
                username.isNotEmpty &&
                (password == null || password.isEmpty)));
      }
      if (_missingUpstream(error)) {
        throw GitUpstreamException(_upstreamMessage('push'));
      }
      rethrow;
    }
  }

  Future<CommandResult> pull(String path,
      {String? remote,
      String? branch,
      String? username,
      String? password,
      GitRequestOptions? options}) async {
    if (password != null &&
        password.isNotEmpty &&
        (username == null || username.isEmpty)) {
      throw const InvalidArgumentException(
          'Username is required when using a password or token for git pull.');
    }
    if ((remote == null || remote.isEmpty) &&
        (branch == null || branch.isEmpty)) {
      var hasUpstream = false;
      try {
        hasUpstream = jsTrim((await _run([
          'rev-parse',
          '--abbrev-ref',
          '--symbolic-full-name',
          '@{u}'
        ], path, options))
                .stdout)
            .isNotEmpty;
      } catch (_) {}
      if (!hasUpstream) throw GitUpstreamException(_upstreamMessage('pull'));
    }
    List<String> args(String? resolved) {
      final target = resolved ?? remote;
      return [
        'pull',
        if (target != null && target.isNotEmpty) target,
        if (branch != null && branch.isNotEmpty) branch
      ];
    }

    if (username != null &&
        username.isNotEmpty &&
        password != null &&
        password.isNotEmpty) {
      final target = await _resolveRemote(path, remote, options);
      return _withCredentials(path, target, username, password, options,
          () => _run(args(target), path, options));
    }
    try {
      return await _run(args(null), path, options);
    } catch (error) {
      if (_authFailure(error)) {
        throw GitAuthException(_authMessage(
            'pull',
            username != null &&
                username.isNotEmpty &&
                (password == null || password.isEmpty)));
      }
      if (_missingUpstream(error)) {
        throw GitUpstreamException(_upstreamMessage('pull'));
      }
      rethrow;
    }
  }
}
