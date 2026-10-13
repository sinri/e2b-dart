import 'dart:io';

const bool isBrowserRuntime = false;

String? environmentValue(String name) => Platform.environment[name];
