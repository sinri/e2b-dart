/// Dart and Flutter client for E2B sandboxes.
library;

export 'src/client.dart';
export 'src/e2b_client.dart';
export 'src/errors.dart';
export 'src/models.dart';
export 'src/commands.dart';
export 'src/filesystem.dart';

export 'src/api.dart' show ApiClient;
export 'src/api_endpoint_client.dart';
export 'src/api_schema_generated.dart';
export 'src/api_paths_generated.dart';
export 'src/connection.dart';
export 'src/logs.dart';
export 'src/mcp.dart';
export 'src/mcp_generated.dart';
export 'src/metadata.dart' show sdkVersion, defaultHeaders;
export 'src/secret.dart';
export 'src/network.dart';
export 'src/paginator.dart';
export 'src/signature.dart';
export 'src/volume.dart';
export 'src/template.dart';
export 'src/build_logger.dart';
export 'src/git.dart';

export 'src/dockerfile.dart' show DockerfileSyntaxException;
