import 'metadata_stub.dart' if (dart.library.io) 'metadata_io.dart' as platform;

/// Dart package version, independent of the pinned JS reference version.
const sdkVersion = '0.1.0';

Map<String, String> get defaultHeaders => {
      'browser': 'unknown',
      'lang': 'dart',
      'lang_version': platform.runtimeVersion,
      'package_version': sdkVersion,
      'publisher': 'e2b',
      'sdk_runtime': platform.runtimeName,
      'system': platform.runtimeSystem,
    };
