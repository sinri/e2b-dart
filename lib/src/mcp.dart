/// Stdio MCP server hosted in a GitHub repository.
class GitHubMcpServerConfig {
  final String runCmd;
  final String? installCmd;
  final Map<String, String>? envs;
  const GitHubMcpServerConfig(
      {required this.runCmd, this.installCmd, this.envs});
  Map<String, dynamic> toJson() => {
        'runCmd': runCmd,
        if (installCmd != null) 'installCmd': installCmd,
        if (envs != null) 'envs': envs,
      };
}
