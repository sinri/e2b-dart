import 'dart:collection';
import 'dart:convert';
import 'errors.dart';

const allTraffic = '0.0.0.0/0';

void validatePlaceholderName(String name, String kind) {
  if (name.isEmpty ||
      name.runes.any(
          (r) => r == 123 || r == 125 || r <= 31 || (r >= 127 && r <= 159))) {
    if (kind == 'iam token') {
      throw InvalidArgumentException(
          "iam token name ${jsonEncode(name)} is not usable: a token name cannot be empty or contain '{', '}' or control characters, because it is interpolated into the '\${e2b.identity.tokens.<name>}' placeholder the egress proxy resolves.");
    }
    throw InvalidArgumentException(
        '$kind name cannot be empty or contain braces or control characters');
  }
}

typedef SandboxIamTokenType = String;

class IamToken {
  final String audience;
  final SandboxIamTokenType tokenType;
  const IamToken({required this.audience, required this.tokenType});
  Map<String, dynamic> toJson() =>
      {'audience': audience, 'tokenType': tokenType};
}

class SandboxIam {
  final Map<String, IamToken?> tokens;
  SandboxIam({this.tokens = const {}});
  Map<String, dynamic>? toJson() {
    final body = <String, dynamic>{};
    for (final entry in tokens.entries) {
      final token = entry.value;
      if (token == null) continue;
      validatePlaceholderName(entry.key, 'iam token');
      body[entry.key] = token.toJson();
    }
    return body.isEmpty ? null : {'tokens': body};
  }
}

/// Read-only mapping that rejects unknown token references during create.
class IamTokenPlaceholders extends MapBase<String, String> {
  final Set<String> _names;
  final bool validate;
  IamTokenPlaceholders(Iterable<String> names, {this.validate = true})
      : _names = Set.of(names);
  @override
  String operator [](Object? key) {
    if (key is! String) {
      throw const InvalidArgumentException('Token name must be a string');
    }
    validatePlaceholderName(key, 'iam token');
    if (validate && !_names.contains(key)) {
      throw InvalidArgumentException(
          "Network transform references unregistered iam token '$key'");
    }
    return '\${e2b.identity.tokens.$key}';
  }

  @override
  Iterable<String> get keys => _names;
  @override
  bool containsKey(Object? key) => _names.contains(key);
  @override
  void operator []=(String key, String value) =>
      throw UnsupportedError('Token placeholders are read-only');
  @override
  void clear() => throw UnsupportedError('Token placeholders are read-only');
  @override
  String? remove(Object? key) =>
      throw UnsupportedError('Token placeholders are read-only');
}

/// Workload identity portion of the official transform callback context.
class NetworkTransformIamContext {
  final IamTokenPlaceholders tokens;
  NetworkTransformIamContext(this.tokens);
}

class NetworkTransformContext {
  final IamTokenPlaceholders tokens;

  /// Official nested shape; [tokens] remains available as a convenience alias.
  NetworkTransformIamContext get iam => NetworkTransformIamContext(tokens);
  NetworkTransformContext(Iterable<String> names, {bool validate = true})
      : tokens = IamTokenPlaceholders(names, validate: validate);
}

class NetworkSelectorContext {
  String get allTraffic => '0.0.0.0/0';
  final Map<String, List<NetworkRule>> rules;
  NetworkSelectorContext(this.rules);
}

typedef NetworkSelector = List<String> Function(NetworkSelectorContext context);
typedef NetworkTransform = Map<String, String> Function(
    NetworkTransformContext context);

/// Materialized outbound request transform. An omitted headers field is
/// distinct from an explicitly empty header map in the official wire format.
class NetworkTransformValue {
  final Map<String, String>? headers;
  NetworkTransformValue({Map<String, String>? headers})
      : headers = headers == null ? null : Map.unmodifiable(headers);
  Map<String, dynamic> toJson() =>
      {if (headers != null) 'headers': Map<String, String>.of(headers!)};
}

typedef NetworkTransformResolver = NetworkTransformValue Function(
    NetworkTransformContext context);

class NetworkRule {
  final Map<String, String>? headers;
  final NetworkTransform? transform;
  final NetworkTransformValue? staticTransform;
  final NetworkTransformResolver? transformResolver;
  NetworkRule(
      {Map<String, String>? headers,
      this.transform,
      this.staticTransform,
      this.transformResolver})
      : headers = headers == null ? null : Map.unmodifiable(headers) {
    if ([headers, transform, staticTransform, transformResolver]
            .where((value) => value != null)
            .length >
        1) {
      throw const InvalidArgumentException(
          'Pass one transform representation only');
    }
  }
  Map<String, dynamic> toJson(NetworkTransformContext context) {
    final value = transformResolver?.call(context) ?? staticTransform;
    if (value != null) return {'transform': value.toJson()};
    final resolved = transform?.call(context) ?? headers;
    return {
      if (resolved != null) 'transform': {'headers': Map.of(resolved)}
    };
  }
}

class EgressProxy {
  final String address;
  final String? username;
  final String? password;
  const EgressProxy({required this.address, this.username, this.password});
  Map<String, dynamic> toJson() => {
        'address': address,
        if (username != null) 'username': username,
        if (password != null) 'password': password
      };
}

class SandboxNetwork {
  final List<String>? allowOut;
  final List<String>? denyOut;
  final NetworkSelector? allowOutResolver;
  final NetworkSelector? denyOutResolver;

  /// Record-style rules: the top-level map is copied when building a request.
  final Map<String, List<NetworkRule>>? rules;

  /// Explicit JS Map semantics: selectors receive this exact map reference.
  final Map<String, List<NetworkRule>>? rulesMap;
  final EgressProxy? egressProxy;
  final bool? allowPublicTraffic;
  final String? maskRequestHost;
  final List<int>? httpsPorts;
  final bool? allowInternetAccess;
  SandboxNetwork(
      {List<String>? allowOut,
      List<String>? denyOut,
      this.allowOutResolver,
      this.denyOutResolver,
      this.rules,
      this.rulesMap,
      this.egressProxy,
      this.allowPublicTraffic,
      this.maskRequestHost,
      List<int>? httpsPorts,
      this.allowInternetAccess})
      : allowOut = allowOut == null ? null : List.unmodifiable(allowOut),
        denyOut = denyOut == null ? null : List.unmodifiable(denyOut),
        httpsPorts = httpsPorts == null ? null : List.unmodifiable(httpsPorts) {
    if (rules != null && rulesMap != null) {
      throw const InvalidArgumentException('Pass rules or rulesMap, not both');
    }
    if (allowOut != null && allowOutResolver != null ||
        denyOut != null && denyOutResolver != null) {
      throw const InvalidArgumentException(
          'Pass selector values or resolver, not both');
    }
  }
  Map<String, dynamic> toJson(
      {SandboxIam? iam, Iterable<String>? tokenNames, bool update = false}) {
    final resolvedRules =
        rulesMap ?? Map<String, List<NetworkRule>>.of(rules ?? {});
    final selector = NetworkSelectorContext(resolvedRules);
    final transforms = NetworkTransformContext(
        tokenNames ??
            (iam?.toJson()?['tokens'] as Map<String, dynamic>?)?.keys ??
            [],
        validate: !update);
    final allowed = allowOutResolver?.call(selector) ?? allowOut;
    final denied = denyOutResolver?.call(selector) ?? denyOut;
    return {
      if (allowed != null) 'allowOut': List.of(allowed),
      if (denied != null) 'denyOut': List.of(denied),
      if (rules != null || rulesMap != null)
        'rules': resolvedRules.map(
            (k, v) => MapEntry(k, v.map((r) => r.toJson(transforms)).toList())),
      if (egressProxy != null) 'egressProxy': egressProxy!.toJson(),
      if (!update && allowPublicTraffic != null)
        'allowPublicTraffic': allowPublicTraffic,
      if (!update && maskRequestHost != null)
        'maskRequestHost': maskRequestHost,
      if (!update && httpsPorts != null) 'httpsPorts': httpsPorts,
      if (update && allowInternetAccess != null)
        'allow_internet_access': allowInternetAccess,
    };
  }
}

enum SnapshotMode { full, filesystem }

enum OnResume { restore, reboot }

enum TimeoutAction { kill, pause }

class SandboxLifecycle {
  final TimeoutAction? onTimeout;
  final SnapshotMode? mode;
  final bool? autoResume;
  final bool? keepMemory;
  const SandboxLifecycle(
      {this.onTimeout, this.mode, this.autoResume, this.keepMemory});
  Map<String, dynamic> toJson() {
    final action = onTimeout ?? TimeoutAction.kill;
    if (action != TimeoutAction.pause && (mode != null || keepMemory != null)) {
      throw const InvalidArgumentException(
          "onTimeout.mode is only allowed when action is 'pause'.");
    }
    if (mode != null && keepMemory != null) {
      throw const InvalidArgumentException(
          'Pass either onTimeout.mode or the deprecated keepMemory, not both.');
    }
    final memory = mode == null ? keepMemory : mode == SnapshotMode.full;
    if (autoResume == true && action != TimeoutAction.pause) {
      throw const InvalidArgumentException(
          "autoResume can only be true when onTimeout action is 'pause'.");
    }
    if (memory == false && autoResume == true) {
      throw const InvalidArgumentException(
          "autoResume: true is not a valid value with mode: 'filesystem' - a filesystem-only snapshot cannot be auto-resumed by traffic and must be resumed explicitly using Sandbox.connect().");
    }
    return {
      if (onTimeout != null) 'autoPause': action == TimeoutAction.pause,
      if (action == TimeoutAction.pause && memory != null)
        'autoPauseMemory': memory,
      if (autoResume != null) 'autoResume': {'enabled': autoResume}
    };
  }
}
