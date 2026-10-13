import 'errors.dart';
import 'js_number.dart';

/// Resolve at connection/request construction, not when storing plain options.
num resolveRetries(num retries) {
  if (!retries.isFinite || retries % 1 != 0 || retries < 0) {
    throw InvalidArgumentException(
        'Invalid retries=${jsNumberString(retries)}: expected a non-negative integer.');
  }
  return retries;
}
