import 'connection.dart';
import 'package:archive/archive.dart';
import 'upload_body.dart';
export 'upload_body.dart';

const supportsStreamingUploads = false;
Future<UploadBody> prepareUpload(Object data,
    {bool gzip = false, CancellationSignal? signal}) async {
  final bytes = await collectUploadBytes(data, signal: signal);
  return UploadBody(gzip ? GZipEncoder().encode(bytes)! : bytes, false);
}
