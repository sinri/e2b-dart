import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'raw_tls_channel_io.dart';

/// HttpClient consumes an already secured origin stream through Socket's public
/// interface. No subsequent TLS upgrade or SDK-private detach is performed.
class RawTlsSocket extends Stream<Uint8List> implements Socket {
  final RawSecureSocket raw;
  final RawTlsChannel channel;
  RawTlsSocket(this.raw) : channel = RawTlsChannel(raw);
  IOSink get sink => channel.output;
  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      channel.input.map((bytes) => Uint8List.fromList(bytes)).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  void destroy() => unawaited(channel.close());
  @override
  int get port => raw.port;
  @override
  int get remotePort => raw.remotePort;
  @override
  InternetAddress get address => raw.address;
  @override
  InternetAddress get remoteAddress => raw.remoteAddress;
  @override
  bool setOption(SocketOption option, bool enabled) =>
      raw.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => raw.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => raw.setRawOption(option);
  @override
  Encoding get encoding => sink.encoding;
  @override
  set encoding(Encoding value) => sink.encoding = value;
  @override
  void add(List<int> data) => sink.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      sink.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => sink.addStream(stream);
  @override
  void write(Object? object) => sink.write(object);
  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      sink.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => sink.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => sink.writeln(object);
  @override
  Future<void> flush() => sink.flush();
  @override
  Future close() => sink.close();
  @override
  Future get done => sink.done;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
