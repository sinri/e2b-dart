const supportsLocalTemplateFiles = false;
String readTemplateFile(String context, String path) => throw UnsupportedError(
    'Local template files are not available in this runtime');

String readDockerfileContent(String input) => input;
