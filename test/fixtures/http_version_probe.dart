import 'package:e2b/e2b.dart';

void main(List<String> args) {
  try {
    print(ConnectionConfig(httpVersion: args.isEmpty ? null : args.first)
        .httpVersion);
  } on InvalidArgumentException catch (error) {
    print(error.message);
  }
}
