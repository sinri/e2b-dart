bool get buildLogIsTerminal => false;
bool get buildLogSupportsAnsi => false;
void writeBuildLog(String text) => print(text.replaceFirst(RegExp(r'\n$'), ''));
