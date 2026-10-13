import 'errors.dart';

bool jsApiTruthy(Object? value) =>
    value != null && value != false && value != '' && value != 0;
String _jsString(Object? value) {
  if (value == null) return 'null';
  if (value is Map) return '[object Object]';
  if (value is List) {
    return value.map((e) => e == null ? '' : _jsString(e)).join(',');
  }
  return value.toString();
}

Object resourceApiError(int status, Object? body, String? reason,
    {bool notFound = false,
    required E2BException Function(String message, int status) fallback}) {
  final message = body is Map ? body['message'] : null;
  final special = status == 401 || status == 429 || status == 503;
  final content = special
      ? message ?? body
      : jsApiTruthy(message)
          ? message
          : jsApiTruthy(body)
              ? body
              : reason ?? '';
  final detail = jsApiTruthy(content) ? _jsString(content) : '';
  if (status == 401) {
    return AuthenticationException(
        'Unauthorized, please check your credentials.${jsApiTruthy(content) ? ' - $detail' : ''}',
        statusCode: status);
  }
  if (status == 429) {
    return RateLimitException(
        'Rate limit exceeded, please try again later${jsApiTruthy(content) ? ' - $detail' : ''}');
  }
  if (status == 503) {
    return ServiceBusyException(
        'Service temporarily unavailable, please retry${jsApiTruthy(content) ? ' - $detail' : ''}');
  }
  if (status == 404 && notFound) {
    return NotFoundException(detail, statusCode: status);
  }
  return fallback('$status: $detail', status);
}
