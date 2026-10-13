# Flutter 平台验收

Flutter 示例在 `example/flutter`；通过宿主注入 E2BClient。Dart 最低版本为 3.5.4。

| 目标 | 当前证据 | 尚未验收 |
|---|---|---|
| Flutter 测试运行时 | 两项组件测试、独立分析通过 | 真设备行为 |
| Web JavaScript/Wasm | Flutter 3.41.5 发布构建通过 | 实际 Flutter 页面网络 |
| Chrome SDK 网络 | 十项本地跨域网络测试通过 | E2B 云端 CORS/联调 |
| macOS | arm64 发布构建、沙盒本地创建/删除、文件读写、Connect 命令流通过 | 云端真实进程 |
| Android/iOS/Windows/Linux | 尚无本机产物证据 | 构建与运行验收 |

macOS 沙盒应用需在 DebugProfile.entitlements 和 Release.entitlements 中启用
`com.apple.security.network.client`（Boolean true）。SDK 无法替宿主应用配置签名权限。
可在 macOS/Xcode 环境执行独立构建检查：

```sh
python3 tool/flutter_macos_check.py /path/to/flutter
```

脚本创建临时 runner、依赖当前源码并复制示例入口，启用出站网络权限。
针对 Xcode 27，把生成工程的 10.15 deployment target 调整为 12.0，
并仅构建宿主机架构；不证明 universal binary 支持。
这只是该 runner 的构建目标，不构成 SDK 对所有旧 macOS 版本的兼容性声明。
默认脚本仅构建；追加 `--network-check` 会启动临时发布应用，验证本地创建/删除请求。
不嵌入真实凭据、不创建云端资源；临时目录保留供检查产物。
