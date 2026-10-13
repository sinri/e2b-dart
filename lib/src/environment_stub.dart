const bool isBrowserRuntime = true;

String? environmentValue(String name) => switch (name) {
      'E2B_API_KEY' => const String.fromEnvironment('E2B_API_KEY').isEmpty
          ? null
          : const String.fromEnvironment('E2B_API_KEY'),
      'E2B_DOMAIN' => const String.fromEnvironment('E2B_DOMAIN').isEmpty
          ? null
          : const String.fromEnvironment('E2B_DOMAIN'),
      'E2B_API_URL' => const String.fromEnvironment('E2B_API_URL').isEmpty
          ? null
          : const String.fromEnvironment('E2B_API_URL'),
      'E2B_SANDBOX_URL' =>
        const String.fromEnvironment('E2B_SANDBOX_URL').isEmpty
            ? null
            : const String.fromEnvironment('E2B_SANDBOX_URL'),
      'E2B_VOLUME_API_URL' =>
        const String.fromEnvironment('E2B_VOLUME_API_URL').isEmpty
            ? null
            : const String.fromEnvironment('E2B_VOLUME_API_URL'),
      'E2B_DEBUG' => const String.fromEnvironment('E2B_DEBUG').isEmpty
          ? null
          : const String.fromEnvironment('E2B_DEBUG'),
      _ => null,
    };
