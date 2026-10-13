import 'package:e2b/e2b.dart';
import 'package:test/test.dart';

void main() {
  test('ConnectionConfig public port and shallow option merging', () {
    expect(ConnectionConfig.envdPort, 49983);
    final previous = ConnectionConfig.envdPort;
    addTearDown(() => ConnectionConfig.envdPort = previous);
    ConnectionConfig.envdPort = 12345;
    expect(ConnectionConfig.envdPort, 12345);
    final nested = <String, String>{'key': 'first'};
    final bound = <String, Object?>{'headers': nested, 'apiKey': 'bound'};
    final opts = <String, Object?>{'apiKey': null, '__proto__': 'plain'};
    expect(ConnectionConfig.mergeOpts<Object?>(null), isNull);
    expect(identical(ConnectionConfig.mergeOpts(null, opts), opts), isTrue);
    final merged = ConnectionConfig.mergeOpts(bound, opts)!;
    expect(identical(merged, bound), isFalse);
    expect(merged['apiKey'], isNull);
    expect(merged['__proto__'], 'plain');
    expect(bound['apiKey'], 'bound');
    expect(identical(merged['headers'], nested), isTrue);
    nested['key'] = 'updated';
    expect((merged['headers'] as Map)['key'], 'updated');
    final copied = ConnectionConfig.mergeOpts(bound)!;
    expect(copied, bound);
    expect(identical(copied, bound), isFalse);
    expect(ConnectionConfig.mergeOpts(<String, Object?>{}, opts), opts);
  });
}
