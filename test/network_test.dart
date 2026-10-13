import 'dart:convert';
import 'package:e2b/e2b.dart';
import 'package:test/test.dart';

void main() {
  test('lifecycle nullable action and legacy memory preserve official defaults',
      () {
    expect(const SandboxLifecycle().toJson(), isEmpty);
    expect(const SandboxLifecycle(autoResume: false).toJson(), {
      'autoResume': {'enabled': false}
    });
    for (final memory in [false, true]) {
      expect(
          SandboxLifecycle(onTimeout: TimeoutAction.pause, keepMemory: memory)
              .toJson(),
          {'autoPause': true, 'autoPauseMemory': memory});
    }
    expect(
        () => const SandboxLifecycle(
                onTimeout: TimeoutAction.pause,
                mode: SnapshotMode.full,
                keepMemory: true)
            .toJson(),
        throwsA(isA<InvalidArgumentException>().having(
            (e) => e.message,
            'message',
            'Pass either onTimeout.mode or the deprecated keepMemory, not both.')));
    expect(
        () => const SandboxLifecycle(
                onTimeout: TimeoutAction.kill, keepMemory: false)
            .toJson(),
        throwsA(isA<InvalidArgumentException>()));
    expect(
        () => const SandboxLifecycle(
                onTimeout: TimeoutAction.pause,
                keepMemory: false,
                autoResume: true)
            .toJson(),
        throwsA(isA<InvalidArgumentException>()));
  });

  test('IAM builds current tokens and skips null entries before validation',
      () {
    final tokens = <String, IamToken?>{'bad{': null};
    final iam = SandboxIam(tokens: tokens);
    expect(iam.toJson(), isNull);
    tokens['service'] =
        const IamToken(audience: 'first', tokenType: 'JWT-SVID');
    final body = iam.toJson()!;
    tokens['service'] =
        const IamToken(audience: 'second', tokenType: 'JWT-SVID');
    expect((body['tokens'] as Map)['service']['audience'], 'first');
    expect((iam.toJson()!['tokens'] as Map)['service']['audience'], 'second');
    tokens['bad{'] = tokens['service'];
    expect(iam.toJson, throwsA(isA<InvalidArgumentException>()));
  });

  test('IAM names report official diagnostics and token types stay extensible',
      () {
    for (final name in ['', 'bad{', 'bad}', 'bad\n', '\u007f', '\u009f']) {
      final message =
          "iam token name ${jsonEncode(name)} is not usable: a token name cannot be empty or contain '{', '}' or control characters, because it is interpolated into the '\${e2b.identity.tokens.<name>}' placeholder the egress proxy resolves.";
      expect(
          () => SandboxIam(tokens: {
                name: const IamToken(audience: 'a', tokenType: 'JWT-SVID')
              }).toJson(),
          throwsA(isA<InvalidArgumentException>()
              .having((e) => e.message, 'message', message)));
      expect(
          () => NetworkTransformContext([], validate: false).tokens[name],
          throwsA(isA<InvalidArgumentException>()
              .having((e) => e.message, 'message', message)));
    }
    const SandboxIamTokenType futureType = 'future-token';
    expect(
        SandboxIam(tokens: {
          '服务': const IamToken(audience: '  audience  ', tokenType: futureType)
        }).toJson(),
        {
          'tokens': {
            '服务': {'audience': '  audience  ', 'tokenType': futureType}
          }
        });
    expect(SandboxIam().toJson(), isNull);
  });

  test('record and explicit Map rules preserve official reference semantics',
      () {
    for (final explicitMap in [false, true]) {
      final source = <String, List<NetworkRule>>{
        'initial': [NetworkRule()]
      };
      final network = SandboxNetwork(
          rules: explicitMap ? null : source,
          rulesMap: explicitMap ? source : null,
          allowOutResolver: (ctx) {
            expect(identical(ctx.rules, source), explicitMap);
            ctx.rules['initial']!.add(NetworkRule());
            ctx.rules['added'] = [];
            return ctx.rules.keys.toList();
          });
      source['late'] = [];
      final first = network.toJson();
      expect((first['rules'] as Map).keys, ['initial', 'late', 'added']);
      expect(source.containsKey('added'), explicitMap);
      expect(source['initial'], hasLength(2));
      network.toJson();
      expect(source['initial'], hasLength(3));
    }
    expect(() => SandboxNetwork(rules: {}, rulesMap: {}),
        throwsA(isA<InvalidArgumentException>()));
  });

  test('selectors share mutable rules before transforms in request order', () {
    final events = <String>[];
    final network = SandboxNetwork(
      rules: {
        'initial': [NetworkRule()]
      },
      allowOutResolver: (ctx) {
        events.add('allow');
        ctx.rules.remove('initial');
        ctx.rules['added'] = [
          NetworkRule(transformResolver: (_) {
            events.add('transform');
            return NetworkTransformValue(headers: {'X-Test': 'yes'});
          })
        ];
        return ctx.rules.keys.toList();
      },
      denyOutResolver: (ctx) {
        events.add('deny');
        expect(ctx.rules.keys, ['added']);
        return [ctx.allTraffic];
      },
    );
    for (var i = 0; i < 2; i++) {
      events.clear();
      expect(network.toJson(), {
        'allowOut': ['added'],
        'denyOut': [allTraffic],
        'rules': {
          'added': [
            {
              'transform': {
                'headers': {'X-Test': 'yes'}
              }
            }
          ]
        }
      });
      expect(events, ['allow', 'deny', 'transform']);
      expect(network.rules!.keys, ['initial']);
    }
  });

  test('official nested IAM context resolves create and update tokens', () {
    final network = SandboxNetwork(rules: {
      'example.com': [
        NetworkRule(
            transformResolver: (ctx) => NetworkTransformValue(headers: {
                  'Authorization': 'Bearer ${ctx.iam.tokens['service']}'
                }))
      ]
    });
    final iam = SandboxIam(tokens: {
      'service': const IamToken(audience: 'example.com', tokenType: 'JWT-SVID')
    });
    final expected = {
      'rules': {
        'example.com': [
          {
            'transform': {
              'headers': {
                'Authorization': r'Bearer ${e2b.identity.tokens.service}'
              }
            }
          }
        ]
      }
    };
    expect(network.toJson(iam: iam), expected);
    expect(() => network.toJson(), throwsA(isA<InvalidArgumentException>()));
    expect(network.toJson(update: true), expected);
    final context = NetworkTransformContext(['service']);
    expect(identical(context.tokens, context.iam.tokens), isTrue);
  });

  test('network transforms preserve absent versus empty headers', () {
    final context = NetworkTransformContext([]);
    expect(NetworkRule().toJson(context), isEmpty);
    expect(
        NetworkRule(staticTransform: NetworkTransformValue()).toJson(context),
        {'transform': <String, dynamic>{}});
    expect(
        NetworkRule(staticTransform: NetworkTransformValue(headers: {}))
            .toJson(context),
        {
          'transform': {'headers': <String, String>{}}
        });
    var calls = 0;
    final rule = NetworkRule(transformResolver: (ctx) {
      calls++;
      return NetworkTransformValue();
    });
    expect(rule.toJson(context), {'transform': <String, dynamic>{}});
    expect(calls, 1);
  });

  test('materialized transform snapshots headers and rejects mixed forms', () {
    final headers = {'X-Test': 'original'};
    final transform = NetworkTransformValue(headers: headers);
    headers['X-Test'] = 'changed';
    final json = transform.toJson();
    expect(json, {
      'headers': {'X-Test': 'original'}
    });
    (json['headers'] as Map)['X-Test'] = 'mutated';
    expect(transform.toJson(), {
      'headers': {'X-Test': 'original'}
    });
    expect(() => NetworkRule(headers: {}, staticTransform: transform),
        throwsA(isA<InvalidArgumentException>()));
    expect(
        () => NetworkRule(
            staticTransform: transform,
            transformResolver: (_) => NetworkTransformValue()),
        throwsA(isA<InvalidArgumentException>()));
  });
}
