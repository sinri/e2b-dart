import 'dart:io';

bool get buildLogIsTerminal => stdout.hasTerminal;
bool get buildLogSupportsAnsi => stdout.supportsAnsiEscapes;
void writeBuildLog(String text) => stdout.write(text);
