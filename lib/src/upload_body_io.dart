import 'connection.dart';
import 'dart:io' as io;
import 'upload_body.dart';
export 'upload_body.dart';

const supportsStreamingUploads = true;
Future<UploadBody> prepareUpload(Object data,
    {bool gzip = false, CancellationSignal? signal}) async {
  signal?.throwIfCanceled();
  if (gzip) {
    return UploadBody(uploadBytes(data).transform(io.gzip.encoder), true);
  }
  return UploadBody(data, data is Stream<List<int>>);
}
