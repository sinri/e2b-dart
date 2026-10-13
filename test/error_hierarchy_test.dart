import 'package:e2b/e2b.dart';
import 'package:test/test.dart';

void main() {
  test(
      'command results need only official fields and exit errors implement them',
      () {
    const result = CommandResult(
        exitCode: 1, stdout: 'out', stderr: 'err', error: 'failed');
    expect(result.pid, isNull);
    final CommandResult error = CommandExitException.fromResult(result);
    expect(error.exitCode, 1);
    expect(error.stdout, 'out');
    expect(error.stderr, 'err');
    expect(error.error, 'failed');
    expect(error.pid, isNull);
    final withPid = CommandExitException.fromResult(
        const CommandResult(pid: 42, exitCode: 1, stdout: '', stderr: ''));
    expect(withPid.pid, 42);
  });

  test('command exit message follows optional server error', () {
    expect(const CommandExitException(1, 'out', 'err').message, '');
    expect(const CommandExitException(1, '', '', error: 'failed').message,
        'failed');
    expect(const CommandExitException(1, '', '', error: '').message, '');
  });

  test('sandbox errors preserve the official common base', () {
    final errors = <E2BException>[
      const NotFoundException('missing'),
      const FileNotFoundException('file'),
      const SandboxNotFoundException('sandbox'),
      const RateLimitException('limited'),
      const CommandExitException(1, '', ''),
      const InvalidArgumentException('invalid'),
      const TemplateException('template'),
      const NotEnoughSpaceException('disk'),
      const GitUpstreamException('upstream'),
      const SandboxNotRunningException('stopped'),
      const SandboxUnreachableException('network'),
    ];
    for (final error in errors) {
      expect(error, isA<SandboxException>(), reason: '$error');
    }
    expect(const RateLimitException('limited').statusCode, 429);
    expect(const ServiceBusyException('busy').statusCode, 503);
  });

  test('resource and authentication errors preserve separate hierarchies', () {
    expect(const SecretNotFoundException('missing'), isA<SecretException>());
    expect(const VolumeNotFoundException('missing'), isA<VolumeException>());
    expect(
        const VolumePathNotFoundException('missing'), isA<VolumeException>());
    expect(const GitAuthException('denied'), isA<AuthenticationException>());
    expect(const FileUploadException('upload'), isA<BuildException>());
    for (final error in <E2BException>[
      const SecretNotFoundException('missing'),
      const VolumeNotFoundException('missing'),
      const VolumePathNotFoundException('missing'),
      const GitAuthException('denied'),
      const BuildException('build'),
      const FileUploadException('upload'),
      const AuthenticationException('denied'),
      const ServiceBusyException('busy'),
    ]) {
      expect(error, isNot(isA<SandboxException>()));
      expect(error, isNot(isA<NotFoundException>()));
    }
  });
}
