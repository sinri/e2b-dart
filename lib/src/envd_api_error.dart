import 'js_number.dart';
import 'errors.dart';

/// Maps envd REST errors; management API errors use a different contract.
Object envdApiError(int status, Object? body, String? reason,
    {bool fileNotFound = false}) {
  final parsed = body is String
      ? body
      : body is Map
          ? body['message']
          : null;
  final value = parsed == null || parsed == false || parsed == 0 || parsed == ''
      ? reason ?? ''
      : parsed;
  final message = _jsMessage(value);
  switch (status) {
    case 400:
      return InvalidArgumentException(message);
    case 401:
      return AuthenticationException(message);
    case 404:
      return fileNotFound
          ? FileNotFoundException(message)
          : NotFoundException(message);
    case 429:
      return RateLimitException(
          '$message: The requests are being rate limited.');
    case 502:
      return formatSandboxUnavailableError(message);
    case 507:
      return NotEnoughSpaceException(message);
    default:
      return SandboxException('$status: $message', statusCode: status);
  }
}

String _jsMessage(Object? value) {
  if (value == null) return 'null';
  if (value is num) return jsNumberString(value);
  if (value is Map) return '[object Object]';
  if (value is List) {
    return value.map((item) => item == null ? '' : _jsMessage(item)).join(',');
  }
  return value.toString();
}
