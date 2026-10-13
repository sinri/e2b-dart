import 'package:e2b/src/http_dispatch_config.dart';
import 'package:test/test.dart';

void main() {
  test('connection limits use official defaults and positive prefix rules', () {
    expect(parseConnectionLimit(null), 100);
    expect(parseConnectionLimit(''), 100);
    expect(parseConnectionLimit('2.9tail'), 2);
    expect(parseConnectionLimit('  +3e4'), 3);
    expect(parseConnectionLimit(null, defaultValue: 200), 200);
    for (final raw in ['0', '-1', '0x10', 'NaN', ' ']) {
      expect(() => parseConnectionLimit(raw), throwsArgumentError);
    }
    expect(
        () => parseConnectionLimit('0'),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
            'Invalid E2B_API_CONNECTIONS=0: expected a positive integer.')));
  });

  test('inflight configuration follows JS decimal parseInt prefixes', () {
    final cases = <String?, num>{
      null: 1000,
      '': 1000,
      '0': 0,
      '-0': 0,
      '+12': 12,
      '1.9': 1,
      '1e3': 1,
      '0x10': 0,
      '12requests': 12,
      '\uFEFF\u00A0 42\n': 42,
      '9007199254740993': 9007199254740992.0,
    };
    for (final entry in cases.entries) {
      expect(parseInflightLimit(entry.key), entry.value, reason: entry.key);
    }
    for (final raw in [' ', 'NaN', 'Infinity', '+', '\u008512']) {
      expect(() => parseInflightLimit(raw), throwsArgumentError, reason: raw);
    }
    expect(() => parseInflightLimit('9' * 400), throwsArgumentError);
    expect(
        () => parseInflightLimit('-2tail'),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
            'Invalid E2B_API_INFLIGHT_REQUESTS=-2: expected a non-negative integer (use 0 to disable the cap).')));
  });
}
