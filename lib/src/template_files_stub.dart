import 'package:http/http.dart' as http;
import 'connection.dart';

List<String> readDockerignore(String context) => [];
Future<String> calculateTemplateFilesHash(String context, String src,
        String dest, List<String> ignorePatterns, bool resolveSymlinks) =>
    throw UnsupportedError('Browser runtime is not supported for copy');

Future<void> uploadTemplateFiles(
        http.Client client,
        Uri url,
        Map<String, String> headers,
        String context,
        String src,
        List<String> ignorePatterns,
        bool resolveSymlinks,
        bool gzip,
        RequestOptions? options) =>
    throw UnsupportedError('Browser runtime is not supported for copy');
