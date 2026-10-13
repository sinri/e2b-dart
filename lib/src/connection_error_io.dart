import 'dart:io';

bool isSocketNetworkError(Object error) => error is SocketException;

/// Only failures proving that no connection was established permit replay of a
/// resource-creating request. Reset, broken pipe and generic timeouts do not.
bool isConnectionEstablishmentError(Object error) {
  if (error is! SocketException) return false;
  if (error.message.startsWith('Failed host lookup:')) return true;
  final code = error.osError?.errorCode;
  final codes = Platform.isWindows
      ? const {10050, 10051, 10061, 10064, 10065, 11001, 11002}
      : Platform.isMacOS || Platform.isIOS
          ? const {50, 51, 61, 64, 65}
          : const {100, 101, 111, 112, 113};
  return codes.contains(code);
}
