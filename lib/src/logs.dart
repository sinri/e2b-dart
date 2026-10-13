/// Console-style SDK logger. JS variadic arguments map to a Dart list.
class Logger {
  final void Function(List<Object?> args)? debug;
  final void Function(List<Object?> args)? info;
  final void Function(List<Object?> args)? warn;
  final void Function(List<Object?> args)? error;
  const Logger({this.debug, this.info, this.warn, this.error});
}
