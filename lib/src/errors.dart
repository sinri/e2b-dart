import 'models.dart' show CommandResult;

/// An error returned by the E2B API or envd Connect service.
class E2BException implements Exception {
  final String message;
  final int? statusCode;
  final String? code;
  const E2BException(this.message, {this.statusCode, this.code});
  @override
  String toString() =>
      'E2BException(${code ?? statusCode ?? "unknown"}): $message';
}

class AuthenticationException extends E2BException {
  const AuthenticationException(super.message, {super.statusCode, super.code});
}

class NotFoundException extends SandboxException {
  const NotFoundException(super.message, {super.statusCode, super.code});
}

class RateLimitException extends SandboxException {
  const RateLimitException(super.message, {super.statusCode = 429, super.code});
}

class CommandExitException extends SandboxException implements CommandResult {
  @override
  final int? pid;
  @override
  final int exitCode;
  @override
  final String stdout;
  @override
  final String stderr;
  @override
  final String? error;
  const CommandExitException(this.exitCode, this.stdout, this.stderr,
      {this.error, this.pid})
      : super(error ?? '');
  factory CommandExitException.fromResult(CommandResult result) =>
      CommandExitException(result.exitCode, result.stdout, result.stderr,
          error: result.error, pid: result.pid);
}

Never throwApiError(Object? body, {int? statusCode}) {
  final data = body is Map ? body : const {};
  final code = data['code']?.toString();
  final message =
      data['message']?.toString() ?? body?.toString() ?? 'Request failed';
  if (statusCode == 401 ||
      statusCode == 403 ||
      code == 'unauthenticated' ||
      code == 'permission_denied') {
    throw AuthenticationException(message, statusCode: statusCode, code: code);
  }
  if (statusCode == 404 || code == 'not_found') {
    throw NotFoundException(message, statusCode: statusCode, code: code);
  }
  if (statusCode == 503) {
    throw ServiceBusyException(message, statusCode: statusCode, code: code);
  }
  if (code == 'invalid_argument') {
    throw InvalidArgumentException(message, statusCode: statusCode, code: code);
  }
  if (statusCode == 429 || code == 'resource_exhausted') {
    throw RateLimitException(message, statusCode: statusCode, code: code);
  }
  throw E2BException(message, statusCode: statusCode, code: code);
}

class InvalidArgumentException extends SandboxException
    implements ArgumentError {
  const InvalidArgumentException(super.message, {super.statusCode, super.code});
  @override
  Object? get invalidValue => null;
  @override
  StackTrace? get stackTrace => null;
  @override
  String? get name => null;
}

class CancellationException extends E2BException {
  const CancellationException(super.message);
}

class ServiceBusyException extends E2BException {
  const ServiceBusyException(super.message,
      {super.statusCode = 503, super.code});
}

class SandboxNotFoundException extends NotFoundException {
  const SandboxNotFoundException(super.message, {super.statusCode, super.code});
}

class FileNotFoundException extends NotFoundException {
  const FileNotFoundException(super.message, {super.statusCode, super.code});
}

class SecretException extends E2BException {
  const SecretException(super.message, {super.statusCode, super.code});
}

class SecretNotFoundException extends SecretException {
  const SecretNotFoundException(super.message, {super.statusCode, super.code});
}

class VolumeException extends E2BException {
  const VolumeException(super.message, {super.statusCode, super.code});
}

class VolumeNotFoundException extends VolumeException {
  const VolumeNotFoundException(super.message, {super.statusCode, super.code});
}

class VolumePathNotFoundException extends VolumeException {
  const VolumePathNotFoundException(super.message,
      {super.statusCode, super.code});
}

class TemplateException extends SandboxException {
  const TemplateException(super.message, {super.statusCode, super.code});
}

class BuildException extends E2BException {
  final String? step;
  const BuildException(super.message,
      {this.step, super.statusCode, super.code});
}

class FileUploadException extends BuildException {
  const FileUploadException(super.message, {super.statusCode, super.code});
}

class NotEnoughSpaceException extends SandboxException {
  const NotEnoughSpaceException(super.message, {super.statusCode, super.code});
}

class GitAuthException extends AuthenticationException {
  const GitAuthException(super.message);
}

class GitUpstreamException extends SandboxException {
  const GitUpstreamException(super.message);
}

class SandboxException extends E2BException {
  final Object? cause;
  const SandboxException(super.message,
      {this.cause, super.code, super.statusCode});
}

class SandboxTimeoutException extends SandboxException {
  const SandboxTimeoutException(super.message, {super.cause});
}

class SandboxNotRunningException extends SandboxTimeoutException {
  const SandboxNotRunningException(super.message, {super.cause});
}

class SandboxUnreachableException extends SandboxTimeoutException {
  const SandboxUnreachableException(super.message, {super.cause});
}

SandboxException formatSandboxUnavailableError(String message) {
  if (message.contains('was not found')) {
    return SandboxNotRunningException(
        "$message: The sandbox was killed or reached its timeout. You can modify the sandbox timeout by passing 'timeoutMs' when starting the sandbox or calling '.setTimeout' on the sandbox with the desired timeout.");
  }
  if (message.contains('port is not open')) {
    return SandboxUnreachableException(
        "$message: The sandbox is running but envd inside it could not be reached (e.g. its network is down). Check the sandbox state with 'Sandbox.getInfo()'.");
  }
  return SandboxUnreachableException(
      "$message: The sandbox could not be reached and its state is unknown — it may have been killed or reached its timeout, or the connection to it was lost. Check the sandbox state with 'Sandbox.getInfo()'.");
}
