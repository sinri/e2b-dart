import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'errors.dart';
import 'js_number.dart';

class FileSignature {
  final String signature;
  final num? expiration;
  const FileSignature(this.signature, this.expiration);
  String? get expirationText =>
      expiration == null ? null : jsNumberString(expiration!);
}

/// SHA-256 + standard base64 (without padding), matching envd's v1 signature.
FileSignature getSignature(
    {required String path,
    required String operation,
    required String envdAccessToken,
    String? user,
    num? expirationInSeconds,
    DateTime? now}) {
  if (envdAccessToken.isEmpty) {
    throw const E2BException(
        'Access token is not set and signature cannot be generated!');
  }
  final computedExpiration = expirationInSeconds == null
      ? null
      : ((now ?? DateTime.now()).millisecondsSinceEpoch / 1000)
              .floor()
              .toDouble() +
          expirationInSeconds.toDouble();
  final expiration = computedExpiration;
  final raw =
      '$path:$operation:${user ?? ''}:$envdAccessToken${expiration == null ? '' : ':${jsNumberString(expiration)}'}';
  return FileSignature(
      'v1_${base64Encode(sha256.convert(utf8.encode(raw)).bytes).replaceAll(RegExp(r'=+$'), '')}',
      expiration);
}
