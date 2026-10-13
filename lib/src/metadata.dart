import 'metadata_stub.dart' if (dart.library.io) 'metadata_io.dart' as platform;

/// Matches the pinned official JS version with a Dart development suffix.
const sdkVersion = '2.55.0-dev.1';

Map<String, String> get defaultHeaders => {
      'browser': 'unknown',
      'lang': 'dart',
      'lang_version': platform.runtimeVersion,
      'package_version': sdkVersion,
      'publisher': 'e2b',
      'sdk_runtime': platform.runtimeName,
      'system': platform.runtimeSystem,
    };
