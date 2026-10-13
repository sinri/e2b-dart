import 'package:e2b/e2b.dart';
import 'package:test/test.dart';

void main() {
  test('sandbox response aliases preserve network rule and lifecycle values',
      () {
    final SandboxNetworkRuleInfo rule = {
      'transform': {'headers': <String, String>{}}
    };
    final SandboxEgressProxyInfo proxy = {'address': 'proxy:1080'};
    final SandboxNetworkInfo network = {
      'rules': {
        'example.test': [rule]
      },
      'egressProxy': proxy,
      'allowOut': <String>[],
      'denyOut': ['0.0.0.0/0'],
      'allowPublicTraffic': false,
      'maskRequestHost': '',
      'httpsPorts': [443, 8443],
    };
    final SandboxInfoLifecycle lifecycle = {
      'onTimeout': 'kill',
      'autoResume': false
    };
    final info = SandboxInfo({
      'sandboxID': 's',
      'network': network,
      'lifecycle': lifecycle,
    });
    expect(info.network, network);
    expect(info.lifecycle, lifecycle);
    expect(SandboxInfo({'sandboxID': 's'}).network, isNull);
    expect(SandboxInfo({'sandboxID': 's'}).lifecycle, isNull);
  });

  test('sandbox info optional names and projected configuration match SDK', () {
    final info = SandboxInfo({
      'sandboxID': 's',
      'alias': '',
      'domain': '',
      'network': {
        'allowOut': ['example.test'],
        'unknown': 'raw-only',
        'egressProxy': {
          'address': 'socks5://proxy',
          'username': '',
          'password': 'secret'
        },
      },
      'lifecycle': {
        'onTimeout': 'pause',
        'autoResume': false,
        'unknown': 'raw-only'
      },
    });
    expect(info.name, isNull);
    expect(info.sandboxDomain, isNull);
    expect(info.network!['allowOut'], ['example.test']);
    expect(info.network!.containsKey('unknown'), isFalse);
    expect(info.network!['egressProxy'],
        {'address': 'socks5://proxy', 'username': ''});
    expect(info.lifecycle, {'onTimeout': 'pause', 'autoResume': false});
    expect(info.raw['network']['unknown'], 'raw-only');
    expect(info.volumeMounts, isEmpty);
  });

  test('sandbox dates and metrics use JS UTC millisecond precision', () {
    final info = SandboxInfo({
      'sandboxID': 's',
      'startedAt': '2026-10-12T08:00:00.123456+08:00',
      'endAt': '1969-12-31T23:59:59.999999Z',
    });
    expect(info.startedAt!.toIso8601String(), '2026-10-12T00:00:00.123Z');
    expect(info.endAt!.toIso8601String(), '1969-12-31T23:59:59.999Z');
    expect(SandboxInfo({'sandboxID': 's'}).startedAt, isNull);
    final metric = SandboxMetrics({
      'timestamp': '2026-10-12T08:00:00.123456+08:00',
      'cpuUsedPct': 1.5,
      'cpuCount': 2,
      'memUsed': 3,
      'memTotal': 4,
      'diskUsed': 5,
      'diskTotal': 6,
    });
    expect(metric.timestamp.toIso8601String(), '2026-10-12T00:00:00.123Z');
  });
}
