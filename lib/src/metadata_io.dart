import 'dart:io';

String get runtimeVersion => Platform.version.split(' ').first;
String get runtimeSystem => Platform.operatingSystem;
const runtimeName = 'dart';
