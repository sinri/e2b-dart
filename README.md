# E2B Dart / Flutter SDK

纯 Dart 实现的 E2B SDK，可用于 Dart CLI、服务端以及 Flutter 移动端、桌面端和 Web。使用 `package:http`，通过条件导入分别适配原生网络与 Web，无需依赖 Flutter。

这是社区移植项目，不是 E2B 官方发布的 Dart SDK。实现参照 [E2B 官方文档](https://docs.e2b.dev/) 与 [JS SDK 2.55.0](https://github.com/e2b-dev/E2B/tree/df6c368152b067512702fc677952c0fc4e13c2f0/packages/js-sdk)，固定参考提交 `df6c368152b067512702fc677952c0fc4e13c2f0`。传输直接使用 E2B REST 与 envd Connect JSON 协议，不需要 Node.js 中转。

版本号跟随所对齐的官方 JS SDK：当前为 `2.55.0-dev.1`。开发迭代递增 `-dev.N`，候选发布使用 `-rc.N`；通过完整验收后移除尾缀。版本对齐表示参考基准一致，不代表已通过完整等价验收。

## 平台验证状态

当前已验证 Dart 3.5.4 测试运行、Chrome 本地网络、Flutter Web JavaScript/Wasm 构建，以及 macOS arm64 沙盒应用的本地管理/文件/命令协议。
Android、iOS、Windows、Linux 与 E2B 云端尚未完成验收；详见仓库的 `docs/FLUTTER_PLATFORMS.md` 和 `docs/PROGRESS.md`。目前不能视为全部平台和云端功能已交付。

## 本地使用

要求 Dart >= 3.5.4。包尚未发布到 pub.dev，先添加路径依赖：

```yaml
dependencies:
  e2b:
    path: /absolute/path/to/e2b-dart
```

```dart
import 'package:e2b/e2b.dart';

Future<void> example(String apiKey) async {
  final client = E2BClient(apiKey: apiKey);
  Sandbox? sandbox;
  try {
    sandbox = await client.create(
      template: 'base',
      timeout: const Duration(minutes: 5),
      metadata: {'project': 'dart-demo'},
      envs: {'GREETING': 'Hello'},
    );
    await sandbox.files.write('/tmp/hello.txt', 'Hello from Dart!');
    final result = await sandbox.commands.run('cat /tmp/hello.txt');
    print(result.stdout);
    print(sandbox.getHost(8080));
  } finally {
    try { await sandbox?.kill(); } finally { client.close(); }
  }
}
```

Flutter 中同样使用上述接口。API key 可由调用方传入；Dart VM 也支持读取 `E2B_API_KEY`（Web 支持编译期 define）。真实项目通常由自己的后端持有团队 API key，客户端通过后端访问。不要把团队密钥打包进公开发布的应用。

## 命令与终端

```dart
final result = await sandbox.commands.run(
  r'echo "$HOME"',
  cwd: '/tmp',
  user: 'user',
  timeout: const Duration(seconds: 30),
  onStdout: (chunk) => print(chunk),
  onStderr: (chunk) => print(chunk),
);

final process = await sandbox.commands.start('cat', stdin: true);
await process.sendInput([72, 105, 10]);
await sandbox.commands.closeStdin(process.pid);
final completed = await process.wait();

final terminal = await sandbox.pty.create(
  cols: 80, rows: 24,
  onData: (bytes) { /* 交给终端组件 */ },
);
await terminal.sendInput([108, 115, 10]); // ls\n
await sandbox.pty.resize(terminal.pid, cols: 120, rows: 40);
await terminal.kill();
await terminal.disconnect();
```

`run` 等待进程退出；`start` 返回句柄，后台继续接收输出。非零退出抛出 `CommandExitException`，其中保留 `exitCode`、`stdout` 和 `stderr`。UTF-8 输出按流增量解码。

命令默认超时 60 秒；`Duration.zero` 禁用命令总时限。PTY 默认无总时限。连接握手仍受 `requestTimeout` 限制。超时或 `disconnect()` 关闭输出连接，远程进程可以继续运行；需要终止进程时调用 `kill()`。`wait()` 可以重复调用。取消目录监听订阅会断开监听连接。

## 文件与生命周期

```dart
await sandbox.files.write('/tmp/data.bin', [0, 1, 255]);
final bytes = await sandbox.files.readBytes('/tmp/data.bin');
final text = await sandbox.files.read('/tmp/hello.txt');
final entries = await sandbox.files.list('/tmp', depth: 2);
final info = await sandbox.files.getInfo('/tmp/data.bin');
await sandbox.files.makeDir('/tmp/new');
await sandbox.files.rename('/tmp/data.bin', '/tmp/new/data.bin');
final exists = await sandbox.files.exists('/tmp/new/data.bin');
await sandbox.files.remove('/tmp/new');

final subscription = sandbox.files.watchDir('/tmp', recursive: true)
    .listen((event) => print('${event.type}: ${event.name}'));
await subscription.cancel();

await sandbox.setTimeout(const Duration(minutes: 10));
await sandbox.pause();
final resumed = await client.connect(sandbox.sandboxId);
await for (final info in client.listAll(state: ['running', 'paused'])) {
  print(info.sandboxId);
}
await resumed.kill();
```

`list()` 返回一页及 `nextToken`；`listAll()` 自动遍历所有页。生命周期时长使用 Dart `Duration`，发送到管理 API 时向上取整为秒。`makeDir` 已存在时返回 `false`，`exists` 仅在 not-found 时返回 `false`，其他错误正常抛出。`kill` 对已经不存在的沙箱返回 `false`。

通过 `E2BClient(apiUrl: ..., sandboxUrl: ..., httpClient: ...)` 可接入代理、自定义部署或测试客户端。注入的 HTTP client 归调用方管理，默认创建的 client 由 `close()` 释放。管理 API key 仅发给管理 API，envd 使用创建/连接响应中的独立访问令牌。旧 envd (< 0.4.0) 使用默认 `user` 身份。

## 覆盖范围与限制

| 官方 JS 能力 | 当前 Dart 实现 |
| --- | --- |
| 创建、连接/恢复、销毁、暂停、设置超时、查询信息 | 已实现 |
| 列表与分页、metadata/state/template 筛选 | 已实现 |
| 指标、创建快照、公开端口主机名 | 已实现 |
| 命令、流式 stdout/stderr、后台句柄、重连、stdin、终止 | 已实现 |
| PTY 创建、连接、输入、窗口尺寸 | 已实现 |
| 文件文本/二进制读写、上传 metadata、目录操作、stat、监听 | 已实现 |
| Volume 独立管理、元数据、文件和流式读写 | 已实现，使用卷令牌隔离内容鉴权 |
| Secrets CRUD、分页、占位符，IAM token 定义与网络回调 | 已实现 |
| Template 构建 DSL、构建日志 | 开发中 |
| Git 兼容模块（官方已弃用） | 操作与逐次请求配置已实现；完整差分验证待补齐 |
| Fork、网络动态更新、快照列表与删除、签名上传/下载 URL | 已实现 |
| Code Interpreter、Desktop SDK | 独立官方产品，本包未实现 |

未封装的管理端点可使用 `client.request(method, path, body: ..., query: ...)`，返回解码后的 JSON；这不等于完整 JS API 对等覆盖。文件支持 `readStream()`；新 envd 支持流式 octet-stream 上传，旧版本回退到缓冲 multipart。Connect 帧最大 16 MiB。管理 API 按官方重放规则重试（默认 3 次），创建遇到 502 不重放。不会自动销毁沙箱。Web 网络访问仍受 E2B/代理的 CORS 配置约束。

## 验证

```sh
dart pub get
dart analyze --fatal-infos
dart test
dart compile js example/web.dart -o /tmp/e2b-web.js
```

测试使用模拟 HTTP 服务验证协议封包、流式分片、UTF-8、鉴权隔离、分页、错误、PTY、监听与超时，不消耗 E2B 配额。真实服务冒烟测试会创建一个付费沙箱，结束时在 finally 中销毁：

```sh
E2B_API_KEY=your-key dart run example/main.dart
```

尚未使用真实账号完成云端联调；VM/Web 编译与单元测试不能替代真实服务验证。

完整等价移植仍在进行，逐项差异和验证状态见 [docs/PARITY.md](docs/PARITY.md)。

MIT License。参考的官方 JS SDK 许可与版权声明见 [LICENSE](LICENSE)。


也可使用静态工厂：`Sandbox.create(options: RequestOptions(apiKey: apiKey))`
或 `Sandbox.connect(id, options: options)`。工厂创建的句柄用完后调用
`sandbox.close()` 释放内部客户端；删除云端沙箱仍调用 `sandbox.kill()`。
注入 `client:` 时，客户端由调用方关闭。实例 `sandbox.connect()` 由公开扩展提供，
与类静态入口共存；其他静态管理入口尚未全部映射。


`Sandbox.fork(id)` 和实例 `sandbox.fork()` 返回 `List<Object>`，每项为
`Sandbox` 或 `E2BException`，可通过 `is Sandbox` 判断成功。
此前实例方法返回 `SandboxForkResult` 的代码需要迁移；`E2BClient.fork`
继续返回该包装类型。静态 Fork 默认创建的客户端由所有成功句柄共同持有，
请逐个调用 `close()`，最后一个句柄关闭后释放客户端。


底层 JSON 管理 API 可使用 `client.api.GET('/sandboxes/{sandboxID}',
pathParameters: {'sandboxID': id})`。返回 `ApiResponse` 的 `data`、`error`
及原始 `response`；HTTP 错误在 `error` 中，网络和成功 JSON 解析失败仍抛出，错误正文会尝试 JSON 后回退文本。
`parseAs` 支持 `json`、`text`、`arrayBuffer`（返回 `Uint8List`）；
生成 schema 类型、middleware 及 stream/blob/formData 尚未移植。

Minimum supported Dart SDK: **3.5.4** (also applies to Flutter’s bundled Dart SDK). Dart 3.4 lacks the native socket connection factory used by proxy support.

Template also exposes static management/build entry points, for example
`await Template.build(Template().fromPythonImage(), 'my-template', options: RequestOptions(apiKey: key))`.
Use `client.Template` to reuse a configured client; an injected `client:` on a static method remains caller-owned.

Volume management is available through `Volume.create/connect/getInfo/list/destroy`.
Call `close()` on volumes returned by static create/connect to release their owned HTTP client;
use `Volume.destroy(id, ...)` separately to delete persistent storage. Content methods
`volume.list(path)` and `volume.getInfo(path)` are provided by the exported `VolumeContent` extension.

Low-level API calls accept `bodySerializer` returning text, bytes, or null. Map, encoded string, and list-of-pairs bodies with `Content-Type: application/x-www-form-urlencoded` use form encoding; other ordinary bodies retain JSON serialization.

Low-level calls also accept `pathSerializer`, which receives the full endpoint URL and original path parameters. The URL uses any per-call API address override and preserves its base path prefix.

Generated management schemas are exported with an `ApiSchema` prefix. For example, `ApiSchemaNewSandboxV2(templateID: 'base', timeout: 60)` can be passed directly as a low-level request body. Models support `fromJson`, typed getters, and `toJson`; use `ApiSchemaOptional(null)` for an explicitly null optional nullable field. See [schema API support](docs/SCHEMA_API.md) for current limits.

`ApiPaths` provides typed callable bindings, for example `ApiPaths.postV2Sandboxes(client.api, body: ApiSchemaNewSandboxV2(templateID: 'base'))`. Results expose typed `data`, raw `error`, and `raw.response` for status and headers.

Low-level `client.api` and generated `ApiPaths` calls accept `ApiMiddleware` hooks. Register defaults with `client.api.use([...])` and remove them with `eject([...])`. Request hooks run forward; response/error hooks run in reverse. High-level management calls and streaming response hooks are not yet integrated; see [middleware scope](docs/SCHEMA_API.md).
