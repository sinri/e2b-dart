import 'dart:convert';
import 'environment_stub.dart' if (dart.library.io) 'environment_io.dart'
    as env;
import 'js_string.dart';
import 'js_number.dart';

/// Mirrors the official base-10 parseInt prefix semantics, including fractions
/// and trailing text. Empty values alone select the default.
num parseInflightLimit(String? raw,
    {String name = 'E2B_API_INFLIGHT_REQUESTS', num defaultValue = 1000}) {
  if (raw == null || raw.isEmpty) return defaultValue;
  final prefix = RegExp(r'^[+-]?[0-9]+').stringMatch(jsTrim(raw));
  final parsed = prefix == null ? double.nan : double.parse(prefix);
  if (!parsed.isFinite) {
    throw ArgumentError(
        'Invalid $name=${jsonEncode(raw)}: expected an integer.');
  }
  if (parsed < 0) {
    throw ArgumentError('Invalid $name=${jsNumberString(parsed)}: expected a '
        'non-negative integer (use 0 to disable the cap).');
  }
  return parsed;
}

num get apiInflightLimit =>
    parseInflightLimit(env.environmentValue('E2B_API_INFLIGHT_REQUESTS'));

enum HttpDispatchScope { api, envdRest, envdRpc }

num inflightLimitFor(HttpDispatchScope scope) {
  final name = switch (scope) {
    HttpDispatchScope.api => 'E2B_API_INFLIGHT_REQUESTS',
    HttpDispatchScope.envdRest => 'E2B_ENVD_INFLIGHT_REQUESTS',
    HttpDispatchScope.envdRpc => 'E2B_ENVD_RPC_INFLIGHT_REQUESTS',
  };
  return parseInflightLimit(env.environmentValue(name),
      name: name, defaultValue: scope == HttpDispatchScope.api ? 1000 : 2000);
}

num parseConnectionLimit(String? raw,
    {String name = 'E2B_API_CONNECTIONS', num defaultValue = 100}) {
  if (raw == null || raw.isEmpty) return defaultValue;
  final prefix = RegExp(r'^[+-]?[0-9]+').stringMatch(jsTrim(raw));
  final parsed = prefix == null ? double.nan : double.parse(prefix);
  if (!parsed.isFinite) {
    throw ArgumentError(
        'Invalid $name=${jsonEncode(raw)}: expected an integer.');
  }
  if (parsed < 1) {
    throw ArgumentError(
        'Invalid $name=${jsNumberString(parsed)}: expected a positive integer.');
  }
  return parsed;
}

num connectionLimitFor(HttpDispatchScope scope) => switch (scope) {
      HttpDispatchScope.api =>
        parseConnectionLimit(env.environmentValue('E2B_API_CONNECTIONS')),
      HttpDispatchScope.envdRest => 10,
      HttpDispatchScope.envdRpc => parseConnectionLimit(
          env.environmentValue('E2B_ENVD_RPC_CONNECTIONS'),
          name: 'E2B_ENVD_RPC_CONNECTIONS',
          defaultValue: 200),
    };
