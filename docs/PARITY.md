# 官方 JS SDK 等价移植进度

目标是完整等价移植 `e2b` JS SDK **2.55.0**，固定提交
`df6c368152b067512702fc677952c0fc4e13c2f0`。不以当前已实现子集作为完成标准。
`@e2b/code-interpreter` 和 `@e2b/desktop` 是独立包，不属于该 SDK 的导出面。
SSH 文档示例并非此版本 `e2b` 包导出的独立模块。

阶段计划、模块完成度与推进记录见 [PROGRESS.md](PROGRESS.md)。

机器可读方法候选清单见 [parity.json](parity.json)。可运行：

```sh
python3 tool/inventory_upstream.py /tmp/e2b-upstream
```

顶层导出清单见 [exports.json](exports.json)：163 个条目，其中 113 个仅类型导出，71 个导出已有部分映射，92 个其他导出待映射审计。
`mapped_partial` 仅表示记录了 Dart 符号及局部证据，构造参数、字段和抛出路径仍需审计。
可用 `python3 tool/inventory_exports.py /tmp/e2b-upstream` 重建，加 `--check` 检查一致性。
该脚本记录固定入口的命名/默认及模板通配导出，不推断成员、重载或行为等价。

清单不是完整性验证器：它折叠重载，尚未逐项记录导出类型、属性/getter、顶层函数和底层传输行为。
`implemented` 仅表示已有实现；`partial` 表示明显存在参数或行为差距；`pending` 表示尚未审计或实现。
测试路径是已存在的单元测试证据，不代表覆盖该方法全部情形，更不代表通过云端联调。

## 已落实并有单元测试的新增行为

- 管理请求：分页逐次选项与绑定配置合并（省略字段继承、显式空 headers 清除绑定 headers）、空成功页及失败游标保留；list/listPaginator 的 startedAfter 使用 JS 毫秒 UTC 格式，list 的空成功响应映射空页；每次调用配置覆盖、隔离客户端默认值、自动读取 VM 环境变量、取消、总请求时限、HTTP 429/502/503 重试规则和可重放 POST 白名单。
- 生命周期：省略未指定 autoPause/autoResume、磁盘模式暂停和快照、重复暂停返回 false、恢复时 reboot、Fork 逐项成功/错误结果。
- 管理资源：Secrets CRUD/分页/存在检查；快照创建/筛选分页/删除；Volume 管理、目录、元数据、文件内容、流式上传/下载。
- 网络与 IAM：token 名称校验、注册名称检查、占位符、同步转换回调、allow/deny selector 回调、动态网络更新、SOCKS5 proxy 序列化。
- 本地辅助：文件 URL SHA-256 签名、MCP URL/token（空 token 下次重新读取，非空原样缓存）；文件 Stat/Move 缺少 entry 时使用官方明确错误，list depth 校验使用 InvalidArgumentException；create 设置 MCP 时默认 mcp-gateway，显式 template 优先；响应空 domain/trafficAccessToken 按官方规范化；URL 路径编码；新版 envd symlink 标记映射。
- 命令逐次配置：命令、PTY、句柄操作支持 RequestOptions；Git 通过 requestOptions 转发。验证握手时限、预先取消、调用中取消、原因保留与连接释放。
- 文件系统监听：目录 RPC 逐次配置；watch() 等待启动后返回 WatchHandle，支持异步回调背压、退出原因、重复停止、终态回调异常处理；递归/entry/网络挂载版本门槛。
- envd 健康与错误：isRunning 使用 /health；RPC 与监听/命令流区分明确停止、端口不可达、模糊故障，后者独立探测 /health；保留原异常 cause，取消不触发探测。
- 文件批量/gzip：writeFiles 支持单次 multipart 或并发 octet-stream，返回顺序与输入一致；gzip 在 VM 流式压缩、Web 缓冲压缩，旧 envd 回退 multipart；metadata 字符校验与 0.6.2 版本门槛。
- 文件 HTTP 错误：读取、流式下载、octet-stream 和 multipart 上传的连接故障接入健康探测；文件 404/507 使用专用异常；目录 RPC 的 not_found 映射为 FileNotFoundException。
- 流式传输：命令 UTF-8 分片、异步 stdout/stderr/PTY 回调背压、回调错误传播、断开时停止派发及流提前关闭的 UTF-8 尾部刷新；PTY、文件读取、上传版本回退、取消空闲连接及文件流 idle timeout。
- Docker ignore：移植官方 PatternMatcher 的清理、父目录结果、有序否定、** 优化、字符类与转义、mayMatchUnder；195 项测试包含固定上游测试表。工具 generate_dockerignore_vectors.py 可重建；Apache-2.0 来源见 THIRD_PARTY_NOTICES.md。
- Dockerfile 基础导入：内容/路径、FROM、RUN/COPY/ADD、ENV/ARG、USER/WORKDIR、启动命令组合与官方拒绝规则；15 个输入向量来自固定官方 TypeScript 转换器。工具 generate_dockerfile_vectors.py 可重建。RUN/COPY heredoc、shebang、tab chomp、多 heredoc、引用和展开规则已实现，包含真实 shell 执行测试；ShellLex 已移植并通过 577 个固定上游测试向量；完整 AST 差分仍待补齐，不能视为完整导入。
- COPY 构建：归档落盘并从磁盘上传，准确 Content-Length、预签名 headers、独立 1 小时上传时限、finally 清理临时目录；模拟验证缓存命中/未命中/强制上传/上传拒绝不触发构建及 API Key 隔离。
- COPY hash：文件/目录/符号链接/断链的 SHA256 与 Node stat/hash 对照；排除目录 size 和 mtime；Template.toJSON 默认异步计算，可关闭 hash 且不修改原指令。
- Template：构建 DSL、镜像及 registry 配置、ready 命令、Dockerfile 导出、构建请求/轮询/终态日志排空、tag 管理及 devcontainer helpers。日志支持官方 ANSI 清理和毫秒时间精度。defaultBuildLogger 已提供等级过滤、终端计时/动画、ANSI 输出及可注入 Flutter 输出；默认时间采用本地 24 小时格式，JS 则依赖宿主 locale。
- Git：`sandbox.git` 已提供 init、remoteAdd/remoteGet、status、branches、分支创建/切换/删除、add、commit、reset、restore、config、configureUser 和 credential helper。解析器保留固定版本的状态优先级及计数语义。

## 仍须实现或深入验证

1. **Template 剩余能力**：语法/警告完整差分、已有接口的完整行为审计。包安装辅助的空字符串行为已对齐（pip 安装当前目录、npm/bun 省略包参数），Dockerfile skipCache 整镜像/层失效已有回归验证。toJSON 已异步计算 COPY hash；ignore 匹配器已按官方 Moby 实现移植并通过上游匹配表、Windows 分隔符及 Unicode/转义用例；Node glob 的文件枚举语义仍需完整差分补齐。COPY 已接入 tar/tar.gz 归档、缓存查询、强制上传、固定 Content-Length PUT 和构建提交；系统 tar/stat 依赖及 Windows 适配仍需解决，归档属性完整差分和超大文件/超时验证仍待完成。
2. **Git 剩余验证与参数**：clone、push、pull、HTTP(S) URL 凭据处理与恢复、认证/上游错误映射已实现并测试；逐次请求时限/取消已通过 GitRequestOptions.requestOptions 接入，WHATWG URL 的完整边界与真实 git 服务仍需差分/联调。虽已被官方弃用，仍属于此固定版本的导出面。
3. **envd 行为与参数**：命令/目录/PTY 参数仍需完整行为审计；PTY create/connect 默认 60 秒、显式 Duration.zero 禁用时限已对齐并验证请求头；命令句柄 sendStdin/closeStdin、文本/字节输入及 stdin 0.3.0/EOF 0.5.2 门槛已实现；版本能力门控与浏览器流式上传限制的端到端验证。文件批量写入、gzip 已实现。网络挂载监听参数/版本门槛、WatchHandle 回调/退出行为已实现。
4. **错误与健康检查**：错误继承已对齐：通用 sandbox 错误使用 SandboxException 基类，Secret/Volume NotFound 归属对应资源，GitAuth 归属 Authentication，FileUpload 归属 Build；Dart 额外保留共同 E2BException 基类；connect 404 已映射 SandboxNotFoundException；create 对 envd < 0.1.0 先 kill 再抛 TemplateException；模板请求/触发/状态映射 BuildException、上传链接映射 FileUploadException、tag/alias 映射 TemplateException，保留 401/429/503 特殊类型；其余映射仍需逐路径审计；RPC/命令/监听及原始文件 HTTP 连接故障已接入独立 5 秒探测，仍需各运行时网络故障差分。HTTP 507 空间不足与文件 404 映射已落实。
5. **连接配置和低层 API**：原生 HTTP 代理及 Basic 认证已接入共享客户端并通过本地真实代理测试，浏览器遵循宿主代理；管理调用及沙箱 RPC 的逐次代理覆盖/继承已实现，两个真实本地代理验证隔离及共享池关闭；Volume atime/mtime/ctime 已统一 UTC 毫秒精度，时区偏移及 epoch 前日期与 Node Date 实际输出对照通过；Secrets 时间已对齐 JS UTC 毫秒精度，fill 无效名称消息包含 JSON 转义原名及官方说明；Secrets CRUD/分页已采用官方状态映射，404 getInfo/update 使用 Secret 标识消息，创建/更新/详情缺失数据抛出明确异常，7 种错误状态及空响应已有测试；Volume 404 消息已匹配官方的 Volume/Path 标识（含流式读取），列表缺失响应和目录非数组响应返回空列表，空 domain 回退连接配置；Volume 管理及内容 API 已按 HTTP 状态映射 401/429/503 专用异常，其他状态为 VolumeException（403 不再误判认证），含普通/流式读取测试；空错误体已回退 statusText，Map/数组错误内容已采用 JS 字符串转换，管理和普通/流式内容读取均已验证；其他异常体边界仍需持续审计；Volume 内容请求空 token/domain/apiUrl 覆盖已按官方回退绑定配置，绑定 token 为空时省略 Authorization，自定义 Authorization 仍优先；Volume 创建及内容元数据/写入响应缺失时已按官方抛出 Response data is missing，空文件读取和删除仍允许空响应；Volume 上传已复用平台适配：原生流式传输不设客户端超时，Web 先缓冲流再使用普通请求超时；缓冲字节内容和原生延迟生产者已验证，Web 示例编译通过，Web Volume 上传已在 Dart 3.11.3/3.5.4 编译为 JS 并用 Node 注入 HTTP 客户端执行字节/认证/结果检查，CI 已纳入；真实浏览器网络上传待验证；Volume 内容 API 已携带默认 SDK 元数据、允许自定义请求头覆盖，并接入逐次 Logger 的请求/响应状态日志（与官方一致，不继承管理 Logger）；Volume debug 已继承 create/connect 的逐次配置，支持内容请求显式 false 覆盖，显式 apiUrl 优先；Volume 内容传输已继承 create/connect 的代理并支持逐次覆盖，真实本地代理验证普通读取、流式读取及 token 隔离，空字符串按官方行为回退到绑定代理；HTTPS 代理服务器和 HTTP/2 等价方案仍待完成；Logger 已接入管理请求/响应状态、RPC 请求/响应及流消息，支持绑定和逐次覆盖，日志消息使用独立 JSON 副本，流日志回调抛错经 wait 传播并释放连接，日志副本修改不影响命令输出；连接前失败安全重试已实现（DNS/拒绝连接/主机与网络不可达，含真实 IOClient TCP 拒绝连接验证）；其他运行时错误分类仍需差分审计；debug 创建/连接/kill/metrics 及实例 setTimeout 跳过云端请求已实现；默认管理请求元数据和 User-Agent/集成标识已实现，语言/版本使用 Dart 实际值；Web browser/system/lang_version 暂为 unknown，宿主识别仍待完善；API schema 等价暴露。`validateApiKey` 已作为无效果的弃用兼容参数接入，符合固定官方版本；debug getHost 已使用 localhost。沙箱 RPC/文件请求在原生支持域名使用共享入口，签名文件 URL 保持直连；浏览器直连分支已编译为 JS 并实际执行路由检查。
6. **结果类型**：完整导出类型/常量/属性映射仍需审计；McpServer 及 265 种配置由固定官方 schema 生成，GitHub 自定义仓库使用 githubRepositories，全部配置字段已有序列化测试；McpServerName 枚举覆盖 265 个服务名并接入 Template.addMcpServer，全部名称的安装命令及镜像限制已验证；ProcessInfo 已从 protobuf config 扁平映射并作为 commands.list 的返回类型，PTY sendInput/kill 资源入口已补齐；文件 WriteInfo 公共接口已导出，EntryInfo 空 metadata 映射 null、modifiedTime 对齐 JS 毫秒精度；额外可选字段仍需审计；Dart 静态/实例同名限制下的资源门面。命令句柄 exitCode/error getters 已实现；非零退出异常保留服务端 error，零退出即使附带 error 也返回结果，符合固定官方版本。
7. **验证与打包**：官方行为差分/固定向量；Dart 最低版本、Flutter 各目标验证；真实服务端联调；完整性审计后才能宣告目标完成。

## 当前验证

- 1309 项模拟/协议测试在 Dart 3.11.3 上完整通过；同一批 1301 项在 Dart 3.5.4 上完整通过。
- 两个版本的严格静态分析通过；Dart 3.4.0 的最低版本验证仍待完成。
- Web JavaScript 在 Dart 3.11.3/3.5.4 编译通过；3.5.4 产物已用 Node 执行浏览器分支路由检查，CI 已纳入该运行检查。
- pub publish --dry-run 完成内容检查，提示缺少 homepage/repository 和 docs 目录命名；未执行发布。
- 尚未运行真实 E2B 云端测试；已提供 `example/main.dart` 用于验证文件与命令主流程。

## 设计映射

- JS 的 Duration 毫秒参数映射为 Dart `Duration`；管理 API 时长仍向上取整为秒。
- JS `E2B.Secret`/`E2B.Volume` 映射为 `client.secrets`/`client.volumes`，沙箱静态操作当前映射到 `client`。
- JS `Array<Sandbox | Error>` Fork 结果映射为 `List<SandboxForkResult>`，每项保留 sandbox 或 typed error。
- Blob/ArrayBuffer 的二进制等价表示为 Dart `Uint8List`；ReadableStream 为 `Stream<List<int>>`。

- JS 回调式 files.watchDir 映射为 Dart files.watch；files.watchDir 保留 Stream 入口。WatchHandle.done 是便于等待清理的 Dart 扩展。

- JS files.write(files) 批量重载映射为 Dart files.writeFiles(List<WriteEntry>)。

MCP 类型可用 `python3 tool/generate_mcp_types.py /tmp/e2b-upstream` 重建，随后运行 `dart format lib/src/mcp_generated.dart test/mcp_generated_test.dart`。生成器校验上游提交，字段类型与 required 来自官方 schema。

Git clone 的 branch/depth/path 36 种组合及凭证清理失败顺序已按固定官方源码补充回归，Git 专项 17 项通过。GitCloneOpts 已记录部分映射；URL 完整语义与真实服务验收仍待完成。

Git push/pull 的 remote/branch 空值、setUpstream 默认与分支删除 force，以及 remoteAdd 的 fetch/overwrite 四种 shell 分组均有固定官方实现对照回归。Git 专项 19 项通过；完整回归 1275 项及严格静态分析通过。

GitConfigOpts 和 GitDangerouslyAuthenticateOpts 已记录部分映射，并核对 scope 路径处理、配置值 trim、认证 host/protocol 默认及空值，以及首步失败停止后续命令。Git 专项 21 项通过；Dart scope 枚举限制非法输入，官方 JS 对动态非法 scope 运行时抛错。

网络 transform 新增 NetworkTransformValue 与 NetworkTransformResolver，通过 NetworkRule.staticTransform/transformResolver 支持官方可省略 headers 的对象与回调；transform: {} 和 transform: {headers: {}} 保持区分。完整回归 1279 项、严格静态分析通过。

网络 transform 回调新增官方 ctx.iam.tokens 访问结构，与原 ctx.tokens 共用占位符映射。回归验证创建时校验已注册名称、更新时允许未知名称，网络专项 3 项通过。规则、selector、egressProxy 和 create/update 选项已建立部分映射，完整规则规范化仍待审计。

网络 selector 上下文改为每次请求独立的可修改 rules 集合，allowOut、denyOut 和后续 transform 依次共享修改结果。完整回归 1281 项、严格静态分析通过。后续已补齐 rulesMap 显式引用形式，rules 改为请求时浅复制，对齐普通对象与 Map 两种语义。

SandboxNetwork.rules 按官方普通对象语义在每次请求浅复制，rulesMap 按显式 Map 语义保留同一引用；嵌套规则列表共享，构造后的源对象修改可见。新增回归验证两种形式的跨请求副作用；完整回归 1282 项、严格静态分析通过。

IAM 名称校验错误消息已与官方对齐；新增 SandboxIamTokenType 字符串别名，允许未来服务端类型。网络专项 6 项及严格静态分析通过。后续已改为请求构建时读取并校验 tokens，关闭引用与时机差异。

IAM 构建时读取源 tokens，跳过 null 后校验有效名称；create 只构建一次 IAM 并在网络回调前固定注册名称，后续源修改不会改变已生成请求体。完整回归 1284 项、严格静态分析通过。

SandboxLifecycle 支持省略 onTimeout，不再强制明确 kill；新增官方兼容 keepMemory 选项，mode/keepMemory 互斥及 pause/autoResume 校验消息对齐。完整回归 1285 项、严格静态分析通过。

betaPause 客户端及实例别名补齐 keepMemory 参数；pause 的 mode/keepMemory 冲突消息按官方对齐。管理专项 16 项及严格静态分析通过，完整回归仍为上批 1285 项。

沙箱列表空 template 已按官方省略，新增 SandboxState/SandboxListOrder 字符串别名，并验证排序、状态、limit 与游标。分页专项 4 项及严格静态分析通过；查询源引用行为与完整分页模型差异仍待审计。

沙箱分页器逐页读取 metadata/state 源集合，构造后和两页间修改可见，limit 与 nextToken 按分页状态传递。完整回归 1288 项、严格静态分析通过。

快照分页新增两页筛选/游标/终止回归，Fork 数量范围错误消息按官方对齐。分页与管理专项 22 项及严格静态分析通过；完整回归仍为上批 1288 项。

指标查询修复负时间戳半秒舍入方向（与 Node Math.round 对照），并将成功缺失数据按官方返回空列表。完整回归 1290 项、严格静态分析通过；指标专属错误映射仍待审计。

指标专属错误映射已补齐：响应错误 code=404 返回 SandboxNotFoundException，其余非特殊状态使用 SandboxException；HTTP 404 本身不触发专属分支。管理专项 18 项及严格静态分析通过，完整回归仍为上批 1290 项。

快照创建错误对齐官方 code=404 专属分支和通用 SandboxException fallback，新增 400/403/404/409/500、code404 及 429 回归。完整回归 1292 项、严格静态分析通过。

沙箱与快照分页错误映射已对齐官方通用 SandboxException fallback，code404 不触发单资源专属异常；两端点各 6 种状态回归验证失败保留原游标。完整回归 1293 项、严格静态分析通过。

setTimeout 与 updateNetwork 已使用官方单沙箱错误映射，覆盖普通 HTTP 错误及响应 code404 专属分支，两端点各 6 种错误分支验证。完整回归 1294 项、严格静态分析通过。

pause 现按官方响应数值 code409 判断已暂停，普通 HTTP409/空体/字符串 code 不再吞为 false；code404 返回沙箱专属异常。修正此前过宽的测试假设并补齐回归，完整回归 1295 项、严格静态分析通过。

connect/getInfo 对齐官方 code404 分支，普通 HTTP404 使用 SandboxException；connect 专属消息为 Paused sandbox，getInfo 成功无数据报 Sandbox not found。完整回归 1296 项、严格静态分析通过。

kill/deleteSnapshot 仅响应数值 code404 返回 false，普通 HTTP404、空体与字符串 code 不再吞为不存在；其他错误使用官方 SandboxException fallback。完整回归 1297 项、严格静态分析通过。

Fork 请求级 HTTP404 按官方映射源沙箱不存在（保留响应空消息），逐项 404 保持普通 NotFoundException，其他逐项错误使用官方 SandboxException/特殊状态类型与消息；成功无数据返回空列表。完整回归 1298 项、严格静态分析通过。

create API 错误采用官方 SandboxException fallback；Fork 逐项 401/429/503 在 null message 时保留官方纯前缀，修复对象字符串误拼接。完整回归 1299 项、严格静态分析通过。

create 未指定的 timeout/metadata/envs/allowInternetAccess/volumeMounts 改为省略，API 保持默认值控制权，显式空对象/false/空挂载仍传递；删除官方不存在的 timeout 必须为正的 SDK 校验。完整回归 1300 项通过。

create 接受官方已废弃且忽略的 secure 参数，验证 null/false/true 均不写请求体，以及 timeout 零/负/毫秒 ceil 转换。创建/连接/API 选项建立部分映射；完整回归 1301 项、严格静态分析通过。

Commands 与请求/启动/连接选项建立部分映射，JS background 重载对应 Dart start/run 两方法；完整成员审计仍待完成。近期改动已在 Dart 3.5.4 完整复验，1301 项通过。

PTY 创建补齐官方默认 TERM=xterm-256color、LANG/LC_ALL=C.UTF-8，保留显式空覆盖，源 envs 不变；移除官方不存在的 create/resize 尺寸正数前置限制。流协议专项 32 项及严格静态分析通过，完整回归仍为上批 1301 项。

Filesystem read/readBytes/readStream 补齐 gzip 参数，按官方发送 Accept-Encoding: gzip；流式传输支持额外请求头。完整回归 1303 项、严格静态分析通过；真实压缩网络验收仍待完成。

原生 HTTP gzip 读取已通过本地真实 HTTP 服务验证：压缩响应分两段发送，文本/字节/流式读取均还原 UTF-8 数据，检查 Accept-Encoding 请求头。文件流专项 12 项通过；该证据不覆盖 Flutter Web 或 E2B 云服务。

文件内容传输统一通过 EnvdTransport.withOptions，修复逐次客户端解析器被绕过及绑定 signal/logger 丢失。回归覆盖缓冲/流读取选择客户端和预取消不发请求。完整回归 1305 项、严格静态分析通过。

文件 HTTP 错误消息按官方提取字符串/message，缺失或空值回退 HTTP statusText；multipart 同步传入 reasonPhrase。完整回归 1306 项、严格静态分析通过。

multipart 上传改为通过 withOptions 选择客户端并继承 headers/timeout/signal，绑定预取消在读取输入前生效。完整回归 1307 项、严格静态分析通过；multipart 日志仍待补齐。

multipart 日志已补齐官方请求/响应格式与状态等级，响应头到达时记录；回调抛错时取消响应流并传播原错误。完整回归 1308 项、严格静态分析通过。

Filesystem/WatchHandle 已建立部分映射，监听回归覆盖异步回调背压、未知事件跳过、单次 onExit、终端回调失败吞掉及重复 stop。导出清单新增实现/证据文件存在校验并修正 Logger 引用路径；此检查不证明行为完整性。

命令握手按官方要求第一条消息必须为 start，拒绝提前输出且不触发输出回调；监听首事件错误消息对齐 Expected start event。两类失败取消响应流，完整回归 1309 项、严格静态分析通过。

### 分页转换失败的游标状态（2026-10-12）

固定官方提交的 SecretPaginator、SandboxPaginator 和快照分页在 API 错误检查后先调用 updatePagination，再转换结果模型。Dart 通用 Paginator 已调整为同一顺序：成功响应中的模型转换失败也消费当前页，使用新游标；无下一游标则 hasNext=false。JSON 解码和 API 请求失败仍发生在游标更新前。新增回归覆盖有/无下一页、转换异常对象原样传播、失败后释放请求锁以及下一次请求使用新游标。分页专项 8 项、严格静态分析通过；尚未重跑完整套件，最后全套记录为 1309 项。此项不代表所有分页并发与类型行为已完成审计。

### Secrets 公开选项映射（2026-10-12）

核对六种选项与 Secret/SecretPaginator，新增八项部分映射。metadata 省略、显式空替换、非空值，以及空 name/value 直接转发新增协议回归；Secrets/管理专项 36 项通过。管理方法目前位于 client.secrets，Secret 类仅提供静态格式辅助方法；官方 Secret extends ClientFactory 的静态及绑定工厂 API 仍需补齐。列表的 Dart RequestOptions 额外允许绑定 signal，通用分页器的并发拒绝限制也是未关闭差异。本次映射不认定等价验收通过；顶层导出为 129 项部分映射、34 项待审计。

### 分页并发行为收敛（2026-10-12）

官方基类与具体分页器没有请求锁，nextItems 在发起请求时读取当前游标，响应成功后按完成顺序更新分页状态。移除 Dart 独有的并发请求拒绝。控制两个 HTTP 响应的回归证明：并发请求发送同一初始游标；先完成的末页将 hasNext 置 false；晚到成功响应仍可设置新的 nextToken 并恢复 hasNext；晚到 API 错误不覆盖已有状态。关闭上一批记录的分页并发限制差异；官方资源静态/绑定工厂 API 仍待补齐。分页专项 9 项，最新完整回归 1312 项及严格静态分析通过。

### Volume 文本读取解码（2026-10-12）

官方文本读取使用 fetch text 解码，非法 UTF-8 不抛错而以 U+FFFD 替换。Dart readFile 原先使用严格 utf8.decode，会对同一文件抛 FormatException；已开启 allowMalformed。Node TextDecoder 对照非法起始字节、截断多字节、UTF-8 BOM、过长编码四种向量；Dart 文本结果一致，readBytes 保留原始字节。Volume 专项 27 项及严格静态分析通过；完整回归最后记录为 1312 项，本次尚未全套重跑。

### Volume 选项与公开面（2026-10-12）

新增八项部分映射，涵盖 Volume、VolumeApiOpts、VolumeConnectionConfig、metadata/read/write 及两个废弃别名。Dart 将结构化选项表达为 VolumeRequestOptions 和方法命名参数，流空闲超时使用 Duration。新增矩阵验证 makeDir/writeFile 的零 uid/gid/mode、force=false/true 以及省略所有选项，metadata 空更新发送空对象；Volume 专项 28 项通过。未关闭差异：httpVersion/HTTP2、公开独立连接配置类、官方静态/绑定工厂，以及浏览器 Blob 格式。映射状态仍是部分映射，非等价验收。累计 137 项部分映射、26 项待审计。

### Sandbox 文件文本读取解码（2026-10-12）

官方 Filesystem.read 的文本格式通过 fetch parseAs=text 解码，与 Volume 一样替换非法 UTF-8。Dart Filesystem.read 原先严格解码，已开启 allowMalformed，并用四种 Node TextDecoder 对照向量验证非法首字节、截断、BOM 和过长编码；bytes 原始值保持。文件流专项 13 项，最新完整回归 1315 项与严格静态分析通过。该结果不覆盖浏览器真实传输及完整 WHATWG 解码语料。

### 派生客户端请求头覆盖（2026-10-12）

官方 ConnectionConfig.mergeOpts 对选项做浅层覆盖，显式 headers 对象替换绑定对象。Dart E2BClient.withOptions 原先合并两个 Map，导致无法清空继承请求头；已改用 hasHeadersOverride 区分省略与显式传入。回归覆盖未指定继承、空对象清空、apiHeaders 替换以及原客户端不变。SDK 专项 18 项、严格静态分析通过；最后完整回归为 1315 项。本项修复不代表官方静态资源/绑定工厂 API 已补齐。

### 派生客户端路由继承（2026-10-12）

ConnectionConfig 记录调用方显式 apiUrl；E2BClient.withOptions 在 domain/debug 覆盖时保留该地址，没有显式地址时重新按 domain/debug 解析默认地址。修复原实现 domain 覆盖丢失自定义控制端点、debug 覆盖仍使用旧生产地址的问题。SDK 专项 19 项和严格静态分析通过，完整回归最后为 1315 项。多次派生时原始选项继承、逐次 ApiClient 请求路由和环境动态解析仍需继续审计，完整工厂公开 API 尚未补齐。

### 连续派生及逐次管理路由（2026-10-12）

withOptions 仅传递原始显式 apiUrl，不再把解析出的默认地址传回构造器，连续派生时 domain/debug 可继续改变默认地址。显式控制地址跨多次派生保持。ApiClient 的逐次 apiUrl/domain/debug 覆盖统一通过 ConnectionConfig 解析，保留绑定显式地址，并处理显式空 apiUrl 的回退；修复空 URI 请求及 domain 覆盖丢失控制地址。新增真实请求对象断言。SDK/路由专项 25 项，完整回归 1318 项、严格静态分析通过。共享连接选项其他字段、环境动态变化和完整工厂 API 仍待审计。

### Sandbox 信息返回类型（2026-10-12）

新增 SandboxNetworkRuleInfo、SandboxEgressProxyInfo、SandboxNetworkInfo、SandboxInfoLifecycle 公开 Map 别名，network/lifecycle getter 使用对应名称。回归覆盖 rules 的空 transform headers、代理无 username、空 allowOut、false、空 maskRequestHost、httpsPorts 与配置缺省；原测试继续验证密码不出现在投影结果。Map 别名不能静态约束官方 TypeScript 的字段和必填项，此差异明确保留，四项均只记部分映射。模型专项 3 项与严格静态分析通过；累计 141 项部分映射、22 项待审计，最后全套为 1318 项。

### 单页 Sandbox 列表统一（2026-10-12）

Dart 扩展单页 list 原先单独实现 HTTP 调用，额外强制 limit=100 和 1..100 校验，并绕过已对齐的 Sandbox 错误处理。现复用 listPaginator，未指定 limit 时省略查询参数，显式 0/负值/101 原样发送，由服务端处理；筛选编码、错误映射及空结果与官方分页路径共用。新增参数与 403 消息回归，分页/SDK 专项 30 项及严格静态分析通过；最后完整回归为 1318 项。requestTimeout 负值的构造/调用时机差异仍未关闭，需分别审计普通 AbortSignal.timeout 与流 handshake setTimeout。

### 签名函数审计（2026-10-12）

getSignature 缺失 token 错误消息按官方补齐末尾感叹号；移除 Dart 独有 operation 字符串运行时校验，官方仅在 TypeScript 类型中限制 read/write，运行时按原值签名。新增 Node crypto 对照 custom operation 向量及精确错误消息回归。管理专项通过。Dart 同步返回、整数 expirationInSeconds 与官方异步返回/number 的适配差异仍待完整处理；导出累计 142 项部分映射、21 项待审计。请求超时负值校验时机仍为未关闭差异。

### 签名小数过期时间（2026-10-12）

FileSignature.expiration、expirationInSeconds 和 uploadUrl/downloadUrl 的 useSignatureExpiration 由 int 拓宽为 num，正负小数秒可参与签名。有限整数 double 在小于 1e21 的范围内转为 int，避免签名原文多出 .0。Node crypto 的 0.5、-0.5、1.0 三组签名向量回归通过，管理专项 27 项与严格静态分析通过。极小/极大数的 JS Number.toString 格式及 binary64 舍入仍未完整对齐；该函数维持部分映射。最后全套测试记录为 1318 项。

### 签名数字格式边界（2026-10-12）

签名过期时间改用 binary64 加法，新增 jsNumberString 统一 JS 的十进制/科学计数法阈值及零和非有限值表示，FileSignature.expirationText 同时用于签名原文与 URL 参数。移除上一批整数化逻辑，避免 Dart VM toInt 对 1e20 饱和截断。Node 签名对照覆盖 1e-7、1e-6、1e20、1e21 和正负 Infinity；管理专项 27 项、严格静态分析通过。尚未验证完整 shortest-decimal 舍入平局语料，因此不认定所有 Number.toString 行为已等价。最后全套记录仍为 1318 项。

### 数字格式差分语料（2026-10-12）

新增 tool/generate_number_vectors.js，以固定 xorshift 状态生成 2048 个 binary64 位模式，加 15 个边界样本（NaN、正负无穷、负零、subnormal、最大值、安全整数及指数阈值），保存 Node Number.toString 的 2063 项期望。Dart 从十六进制位模式重建 double 后逐项比较，全部一致。该语料避免 JSON 数字解析造成位模式变化，可用 node tool/generate_number_vectors.js 重现。完整回归 1321 项、严格静态分析通过；有限语料不构成全部 binary64 值的形式证明，签名公开 API 仍维持部分映射。

### 构建状态查询选项（2026-10-12）

官方 GetBuildStatusOptions 仅在 ConnectionOpts 上增加 logsOffset:number。Dart 原先 int 限制已拓宽为 num，通过 jsNumberString 序列化；回归确认省略、零、负值、小数、整数 double 与指数值原样查询，以及 templateId/buildId 单段路径编码。未发现官方日志等级筛选选项，不新增该参数。Template 专项 25 项、严格静态分析通过；导出累计 143 项部分映射、20 项待审计。最后全套为 1321 项。

### 模板构建阶段日志（2026-10-12）

构建选项审计发现 buildInBackground 缺少官方四条 info 日志，已按源码顺序补齐 Requesting build for template（包含非空 tags）、Template created with ID/Build ID、All file uploads completed、Starting building。无 COPY 时同样发出上传完成日志，触发构建请求前发出开始日志。构建流程回归验证完整消息序列。Template 专项 25 项及严格静态分析通过；最后完整回归 1321 项。本批尚未完成 BuildOptions/CopyItem 公开面映射。

### CopyItem 批量选项与浏览器限制（2026-10-12）

新增多源 copyItems 选项透传矩阵，覆盖空 user、零 mode、false/true gzip 和 resolveSymlinks 及强制上传。修复 copyItems 原先在浏览器空列表时直接成功、非空列表报 copy 而非 copyItems 消息；现迭代前按官方检查平台。Web smoke 编译 JS 并在 Node 执行非 IO 分支验证空/非空列表，已纳入既有 CI 执行入口。Template 专项 26 项通过；Node PathLike 的 Buffer/URL 与 number mode 范围仍为差异。导出累计 144 项部分映射、19 项待审计。

### 构建日志失败控制流（2026-10-12）

按官方 normalizeBuildArguments 和 try/finally 顺序修复 build：空名称在任何日志前拒绝，Build started 回调放入 try，因此抛错仍发 Build finished；补齐构建启动后的 Waiting for logs。新增四个后台阶段回调失败矩阵，验证原异常传播与后续 HTTP 请求停止。Template 专项 28 项、严格静态分析通过；BuildOptions 映射尚未完成，最后完整回归 1321 项。

### 结构化 BuildOptions（2026-10-12）

新增 BuildOptions，官方 legacy alias 形式通过 Templates.buildWithOptions/buildInBackgroundWithOptions 适配，连接字段放在 connection:RequestOptions。协议回归验证 alias、空 tags、零 cpu/memory/disk、skipCache、四条后台阶段日志及逐次 apiKey。Template 专项 29 项与严格静态分析通过。Dart 使用独立命名方法表达 JS 重载，资源数值仍为 int，完整静态/绑定工厂 API 未补齐；本项只记部分映射。累计 145 项部分映射、18 项待审计，最后全套 1321 项。

### 构建资源 number 参数（2026-10-12）

BuildOptions 以及 build/buildInBackground 的 cpuCount、memoryMB、minFreeDiskMb 由 int 拓宽为 num，官方 SDK 未做整数或正数校验，因此小数/负值原样提交并由服务端判断。协议测试覆盖 0.5/-0.5/1.25 和未指定字段省略，Template 专项 30 项通过。最新完整回归 1327 项及严格静态分析通过。JS JSON.stringify 对 NaN/Infinity 的 null 转换与 Dart JSON 编码差异仍需处理，构建选项维持部分映射。

### 构建非有限值及 Dart 3.5.4 复验（2026-10-12）

构建 cpuCount/memoryMB/minFreeDiskMb 显式 NaN 或正负 Infinity 编码为 null，与 Node JSON.stringify 对照一致；未指定值仍省略字段。关闭上一批记录的这三个字段非有限 JSON 差异，其他 JSON 输入并未由此推定等价。Template 专项 30 项、严格静态分析通过；Dart 3.5.4 最新完整回归 1327 项全部通过，覆盖近期模型、分页、签名数字语料及模板改动。最低 Dart 3.4.0 与真实浏览器/Flutter 云端验证仍待完成。

### DockerfileSyntaxError 结构（2026-10-12）

官方 dockerfile-utils-js/src/syntax.ts 中语法异常直接继承 Error，独立于 TemplateError。Dart DockerfileSyntaxException 原先继承 TemplateException，已改为共同 E2BException 基类并提供 name=DockerfileSyntaxError；message 与可选 line 对齐，测试省略/0/1/-1 行号。该变更会使原来仅捕获 TemplateException 的调用方不再捕获语法错误，应显式捕获 DockerfileSyntaxException 或共同基类。Dockerfile 专项 20 项及严格静态分析通过；完整解析器抛出位置和堆栈仍待审计。累计 146 项部分映射、17 项待审计；最后全套 1327 项。

### MCP 最小配置及公开映射（2026-10-12）

生成器为 265 个服务的测试增加仅必填字段配置，验证可选字段省略，所有 265 项通过。发现固定官方 schema 的 vectraAiRux.required 含 VECTRABASEURL 但 properties 未声明；按官方生成 TS 的字段集合处理，不凭空新增字段。McpServer/McpServerName 建立部分映射；动态 github/<repository> 通过 githubRepositories 表达，Dart enum 尚不能完整表示官方 keyof 中的动态名称。累计 148 项部分映射、15 项待审计；完整声明差分和运行时约束仍待审计，最后全套 1327 项。

### MCP 动态服务名称（2026-10-12）

McpServerName 从封闭 enum 改为可扩展字符串值对象，保留 265 个常量、values 与 name，新增 McpServerName.githubRepository(repository) 表达官方 github/<repository> 动态键。类型化名称与内置服务可混合传入 addMcpServer，验证 gateway pull 命令及值相等/哈希。关闭上一批动态名称无法类型化的差异。使用 enum index 或 exhaustive switch 的调用方需要迁移；官方原类型为字符串键，不包含 enum 的 index 语义。MCP 专项 268 项、严格静态分析通过；最后全套 1327 项。

### Secret 静态管理入口（2026-10-12）

Secret 新增官方五个静态 CRUD/查询方法，委托既有 Secrets 行为；默认构造 ApiClient 并在 finally 关闭，额外 client 参数支持注入调用方管理的客户端，不主动关闭。回归验证五个入口、逐次 apiKey、metadata 空对象及 exists/destroy 的 404=false；Secrets 专项 10 项、严格静态分析通过。static list、官方 E2B 绑定工厂及内部客户端真实网络生命周期验证仍待补齐；最后全套 1327 项。

### Secret 静态分页入口（2026-10-12）

新增公开 SecretPaginator 与 Secret.list，client.secrets.list 同步返回该类型。通用 Paginator 增加每页 clientFactory，默认静态 Secret 分页每页创建并 finally 关闭 ApiClient，注入客户端维持调用方所有权。回归验证成功/错误均关闭内部客户端、失败保留游标和重试使用新客户端；分页/Secrets 专项 21 项、严格静态分析通过。官方 E2B 资源绑定与真实网络仍待验证；最后全套 1327 项。

### Secret 静态本地 HTTP 验证（2026-10-12）

新增本地 HttpServer 集成回归，未注入 HTTP 客户端，直接调用 Secret 静态管理和分页入口；验证认证、带斜杠/空格的单段名称、limit/初始游标、403 后保留游标重试、逐页 apiKey 覆盖与分页结束。证明 Dart VM 实际 HTTP 路径可用，不能推定浏览器或 E2B 云端通过。执行 CI 同范围 dart format lib test example；最新完整回归 1332 项、严格静态分析通过。

### E2B 绑定资源入口（2026-10-12）

新增 E2B extends E2BClient，提供官方大小写的 Sandbox/Secret/Volume/Template 入口，Templates.call 支持 client.Template(...) 创建构建器。验证两个客户端的凭据与 domain 隔离、逐次覆盖不污染绑定配置，以及构建器参数。E2B 专项 1 项、严格静态分析通过。当前 Sandbox 入口暴露 E2BClient，分页需使用 listPaginator，list 仍是 Dart 单页扩展；资源构造器/静态辅助方法的完整类表面尚未等价，不以入口存在判定工厂完成。累计 149 项部分映射、14 项待审计，最后全套 1332 项。

### 绑定 Sandbox 分页形式（2026-10-12）

E2B.Sandbox 改为 SandboxResource，list 返回官方分页器形式，关闭上一批 list 与 listPaginator 命名差异。create/connect/getInfo/kill 透传绑定客户端，原 E2BClient.list 单页扩展保持。E2B 隔离测试改为直接使用 client.Sandbox.list().nextItems()，专项 1 项与严格静态分析通过。其他 Sandbox 管理工厂方法仍需逐项补齐，create/connect 转发也需独立协议回归；最后全套 1332 项。

### Sandbox 管理工厂方法（2026-10-12）

SandboxResource 补齐 getFullInfo、pause/betaPause、setTimeout、updateNetwork、getMetrics、createSnapshot/listSnapshots/deleteSnapshot、fork，所有方法直接透传既有 E2BClient 的参数。协议回归覆盖暂停 memory=false、超时 ceil 秒数、网络 denyOut、指标空结果、快照筛选与删除以及逐次 apiKey；E2B 专项 2 项和严格静态分析通过。create/connect/createSnapshot/fork 工厂透传仍需独立回归，不能由委托代码推定全行为验收；最后全套 1332 项。

### Sandbox 工厂创建及返回配置回归（2026-10-12）

新增绑定 create/connect/createSnapshot/fork 协议回归，覆盖创建模板/空 metadata/envVars/false internet/空挂载、毫秒 timeout ceil、连接 reboot memory=false、快照 filesystem memory=false、Fork count/timeout，及含斜杠 ID 单段编码。创建、连接、Fork 返回沙箱的下载 URL 均继承逐次 sandboxUrl，所有管理请求使用逐次 apiKey。E2B 专项 3 项通过，最后全套 1332 项。该证据关闭上一批缺少四条工厂独立协议回归的问题，不推定真实云端和完整类静态表面等价。

### 绑定 Secret 辅助入口（2026-10-12）

E2B.Secret 使用 SecretResource facade，保留 create/update/getInfo/exists/destroy/list 的绑定委托，并增加可从资源调用的 fill/iamToken。修复原先返回 Secrets 时静态辅助方法无法作为实例成员调用的问题。回归验证 placeholder 与静态 Secret 一致、非法名称错误透传和 tokenType，既有分页隔离测试继续通过；E2B 专项 3 项、严格静态分析通过。所有工厂参数的独立差分审计仍未完成；最后全套 1332 项。

### E2B 结构化配置与派生类型（2026-10-12）

新增 E2BClientOpts 与 E2B.fromOptions；配置构造器不暴露 signal，按官方 Omit<ConnectionOpts, 'signal'> 将取消保留在逐次请求。E2B.withOptions 返回 E2B，避免原先继承方法返回基础客户端后丢失四个资源入口。回归验证结构化 apiHeaders、派生域名/凭据、空 headers 清空以及原客户端隔离、Template 可调用和 null 派生保持同一实例。完整回归 1336 项通过。httpVersion 尚未实现，完整配置默认值和资源工厂绑定语义仍需审计，因此只记部分映射；累计 150 项部分映射、13 项待审计。

### 资源方法提取及配置引用审计（2026-10-12）

核对官方 client.ts 与 template/callable.ts：官方模板 Proxy 将提取的静态方法绑定到资源类。Dart 四个资源的实例方法 tear-off 自带 receiver；新增独立回归提取 Sandbox.list、Secret.list、Volume.list、Template.exists 后调用，四条请求仍使用绑定域名及凭据。先以已取消 signal 调用 Volume.list，确认未发送请求，随后四条无 signal 请求正常，证明该路径的单次取消隔离。E2B 专项 5 项通过。

同时发现未关闭差异：官方 E2B 构造器仅浅复制 opts，apiHeaders 嵌套对象保持引用，而 Dart RequestOptions 和 ConnectionConfig 复制并冻结 headers。调用方在构造之后修改原始 headers Map 时，Dart 不会观察到修改。需要继续跟踪官方资源逐次解析及 ConnectionConfig 的复制时机，再调整绑定存储方式；不能仅修改共享 RequestOptions 以免破坏其他路径的既有语义。最后完整回归仍为 1336 项。

### E2B 绑定请求头引用修复（2026-10-12）

E2B 与 E2BClientOpts 保留调用方 headers/apiHeaders Map 的引用，E2B.headers 在每次读取时通过 ConnectionConfig 生成合并快照。原始 Map 的新增、修改、删除均能影响后续管理请求，apiHeaders 优先于旧 headers；普通 ApiClient/RequestOptions 的快照语义保持。ApiClient 新增 requestHeaders 解析入口供后续完整覆盖规则使用。新增直接及结构化构造双路径回归，E2B 专项 6 项通过、严格静态分析通过。此修复仅关闭绑定默认请求头的实时引用差异；逐次仅覆盖 headers 或 apiHeaders 时，官方按两个独立字段继承，而 Dart 当前已扁平化为一个 Map，此项仍需修复，不能认定请求头全行为等价。

### 请求头独立字段继承（2026-10-12）

按官方 ConnectionConfig.mergeOpts 的逐属性覆盖语义，RequestOptions 增加 legacyHeaders/apiHeaders 两个独立快照字段，headers 保留合并后的兼容读取。merge 分别继承两个字段，省略与显式空 Map 不再混同。E2B.requestHeaders 在请求时分别合并绑定字段与逐次字段；E2B.withOptions 同样保留两条绑定链，不再扁平化后丢失字段来源。回归矩阵覆盖只清空旧字段、只清空新字段、同时清空、旧字段冲突被继承的新字段覆盖，并分别验证直接调用与派生客户端。修正原 api_test 对跨字段清空的错误预期。完整回归 1339 项通过、严格静态分析通过。普通 ApiClient 的低层 additive headers 接口未由此认定等价；Sandbox 返回实例配置、模板上传与内容传输的全链路字段传播仍需审计。

### Sandbox 管理与 envd 请求头边界（2026-10-12）

核对官方 sandbox/index.ts 的 envdApi 与 rpcTransport 初始化：绑定 ConnectionConfig 中只有 User-Agent 转入 envd，其他头由沙箱路由与访问令牌组成。修复 Dart Sandbox._ 将所有管理自定义头展开到 EnvdTransport 的差异，改为只读取 User-Agent。新增创建返回实例的完整回归：创建时清空旧 headers、继承 apiHeaders；文件读取不携带 Legacy/Modern 管理头，仍携带自定义 User-Agent、沙箱 ID 与 envd token；随后 sandbox.getInfo 仍使用正确的管理头。E2B 专项 8 项通过，完整回归 1340 项、严格静态分析通过。命令/PTY 共享同一 EnvdTransport 初始化，但完整逐次选项与 RPC 请求头组合仍待独立审计；不由文件读取测试推定全部流路径等价。

### envd 逐次管理头隔离（2026-10-12）

按官方 commands/index.ts、commands/pty.ts 和 filesystem/index.ts 的 RPC 调用，逐次 ConnectionOpts.headers/apiHeaders 不参与 envd 请求头，认证与 keepalive 等头由具体操作生成。移除 EnvdTransport.withOptions 对 options.headers 的展开；仍转发 timeout/signal/logger/客户端解析。修正旧 streaming 测试中错误的自定义头透传预期，保留命令、PTY input/kill、stdin、目录 RPC 与取消的原有协议断言。新增独立测试同时传旧 headers 与 apiHeaders，确认不覆盖访问令牌和 User-Agent，Basic 用户认证与 Connect 协议版本仍正确。共享修改后完整 1340 项通过；随后新增 transport 专项 6 项通过、严格静态分析通过（新测试尚未再跑全套）。此项不推定所有平台网络和全部 envd 协议已经等价。

### Volume 管理与内容请求头边界（2026-10-12）

核对官方 volume/client.ts：VolumeConnectionConfig.headers 取逐次 opts.headers，VolumeApiClient 在 defaultHeaders 和 volume Bearer token 之后展开内容 headers，因此明确允许逐次覆盖 Authorization。与 envd 不读取管理 headers 的规则不同，不应统一删除。新增 E2B.Volume.create 到 Volume.readFile 的端到端 Mock HTTP 回归：管理 Legacy/Modern/Authorization 不进入内容请求，内容使用服务端返回 domain/token；显式内容头可覆盖 Authorization，后续未指定时恢复 token 且不保留自定义头。当前实现符合本路径，未改动运行时代码。最新完整回归 1342 项、严格静态分析通过，包含上一批新增 transport 测试。真实网络、流格式与全部 Volume 配置仍待验收。

### 分页请求头组合审计（2026-10-12）

官方 SecretPaginator 保存 resolveOpts 结果，每页再 mergeOpts 并构造 ConnectionConfig。新增三页回归：构造时 headers={} 屏蔽绑定旧头；随后修改绑定 apiHeaders，首个请求读取更新值；第二页 apiHeaders={} 只对本页清空；第三页恢复绑定新头，旧头仍被构造选项屏蔽，游标逐页正确。E2B/分页专项合计 20 项通过、严格静态分析通过；最后完整回归仍为 1342 项。

未关闭引用差异进一步定位：E2B 绑定原始 Map 已保留，但分页构造传入 RequestOptions 时，legacyHeaders/apiHeaders 被 Map.unmodifiable 复制；官方分页 opts 中嵌套头仍保留原对象。因此构造分页器之后修改它自己的选项 Map，Dart 不会观察到更新。这与已修复的 E2B 默认头引用是两条不同路径，下一步需要调整 RequestOptions 的保存和请求时快照时机并复验其所有消费者。

### RequestOptions 嵌套请求头引用（2026-10-12）

RequestOptions 改为保留 legacyHeaders/apiHeaders 原始引用，headers getter 在读取时合并为不可变快照。merge 保留两个字段引用，不再在分页构造时复制嵌套 Map；此前取得的 headers 快照不受后续修改影响。新增分页回归覆盖构造后修改字段/删除字段、两页之间清空现代头与新增旧头，确认实际请求逐页读取当前值。完整回归 1344 项通过，严格静态分析通过。关闭上一批定位的分页构造选项嵌套头引用差异；同一请求重试期间的快照时机尚需与官方 ApiClient/ConnectionConfig 分别核对，不由跨页测试推定等价。

### 管理请求重试快照时机（2026-10-12）

官方 ApiClient 从 ConnectionConfig.headers 创建 openapi-fetch 客户端，withRetry 对同一 Request 执行 clone，重试不会重新读取外部选项。Dart 原先每次尝试调用 requestHeaders，导致首次 503 后修改原 Map 会改变重试。现将完整请求头在重试循环之前解析一次，所有尝试使用同一快照；后续独立调用仍重新解析。新增 503/Retry-After:0 回归同时修改 E2B 绑定 headers 和逐次 apiHeaders，确认重试保留 initial、下一调用使用 updated。Dart 3.11.3 与 Dart 3.5.4 完整回归均为 1345 项通过，当前严格静态分析通过。该结果关闭本管理重试路径的头快照差异，其他请求参数、日志回调修改与运行时网络行为仍需完整审计。

### Git 资源公开面与 clone depth（2026-10-12）

核对官方 sandbox/git/index.ts 的 19 个公开 async 方法，Dart Git 均有对应入口，新增 Git 导出部分映射，不将名称对应视为完整行为证明。发现 clone depth 原先 int 限制小于官方 number 范围，现拓宽 num，按官方 if(depth) 省略零和 NaN，其他值通过 jsNumberString 序列化。新增小数、负值、整数 double、指数阈值与正负无穷向量，Git 专项 22 项及严格静态分析通过。最后完整回归仍为 1345 项；WHATWG URL 边界、全部参数/错误与真实 Git 服务验收仍未完成。导出累计 151 项部分映射、12 项待审计。

### Git tracking 计数解析（2026-10-12）

官方 parseAheadBehind 使用 Number.parseInt(text,10)，没有要求 ahead/behind 后存在空白，允许数字前缀并保留解析失败的 NaN。Dart 原先正则要求空白且 int.tryParse 失败回退 0，现按关键词 split 与逗号截断、trim、十进制前缀匹配，再转 binary64。GitStatus.ahead/behind 拓宽 num，以承载 NaN 和 JS 安全整数之外的舍入。Node 对照五组输入，包括无空白、正负号/尾缀、小数、gone、非法数、9007199254740993 与十进制解析 0x10，结果与回归一致。Git 专项 23 项、严格静态分析通过；最后完整回归仍为 1345 项。该返回类型变更使显式赋值到 int 的调用方需要适配；完整 JS trim 字符集合与全部解析边界尚未证明等价。

### Git 解析 ECMAScript 空白集合（2026-10-12）

新增内部 jsTrim，显式采用 ECMAScript WhiteSpace/LineTerminator 集合。Git 状态过滤、tracking 数值前缀和分支列表改用该函数，避免 Dart trim 将 U+0085 当作空白而官方保留的差异。Node 验证全部 25 个空白码点及 U+0085/U+180E/U+200B 三个非空白边界；Dart 回归覆盖分支名保留和 tracking NaN。Git 专项 24 项、严格静态分析通过；最后全套仍为 1345 项。其他 Git 命令输出/config/凭据路径仍有 Dart trim 使用，尚未由本批推定修复。

### Git 剩余 trim 路径收敛（2026-10-12）

核对官方 git/index.ts 全部 trim 调用：remoteGet/getConfig 输出、凭据 host/protocol、远端枚举、临时凭据操作读取原 URL、pull 上游存在检查。Dart 对应路径全部改用 jsTrim；lib/src/git.dart 已无原生 trim 调用。新增 config/remoteGet/凭据 host/protocol 回归，U+0085 原样保留，U+FEFF 按 JS 去除；既有 push/pull 凭据恢复及 remote 枚举测试继续覆盖控制流。完整回归 1349 项、严格静态分析通过，包含近期 clone number、tracking parseInt 和空白集合全部新增测试。此结果关闭已定位的 Git trim 字符集合差异，仍不证明 WHATWG URL、全部错误与真实服务等价。

### Git HTTP URL 控制字符及斜线（2026-10-12）

_gitUri 增加 WHATWG 前处理：移除全局 ASCII tab/LF/CR 和两端 C0/space；HTTP(S) 支持省略 authority 斜线、单斜线和反斜线，并只在 query/fragment 之前转换反斜线。Node 五组有效输入与凭据注入输出对照；Dart 同时验证目录推导 repo，Git 专项 26 项与严格静态分析通过。最后完整回归仍为 1349 项。该前处理不是完整 WHATWG URL 实现：IDNA、IPv4 特殊形式、非法 host、percent-encoding 与 query/fragment 序列化仍未全部对齐；Node 额外观察到查询参数反斜线原样保留，Dart Uri 序列化需继续核对。

### Git 凭据 setter 差分语料（2026-10-12）

新增可重复生成的 tool/generate_git_credential_vectors.js，直接使用 Node URL.username/password setter 生成 128 个 ASCII 字符及 Unicode、孤立高/低代理项、既有百分号编码和混合凭据共 133 组样本，保存 test/git_credential_vectors.json。Dart withGitCredentials 逐项比较完整带凭据 URL，全部一致；本批不需修改编码实现。Git 专项 27 项、严格静态分析通过；最后全套仍为 1349 项。该证据只覆盖给定固定基础 URL 的 setter 编码，不能证明 host/IDNA/IPv4/路径/query/fragment 的 WHATWG 解析与序列化全等价。

### Git 特殊 IPv4 主机（2026-10-12）

新增内部 jsIpv4Host，处理 HTTP(S) special host 的十进制/八进制/十六进制数、短 IPv4、末尾点及每段/整体上界；非数字域名和 IPv6 保留原路径。使用 BigInt 避免解析超大整数时平台溢出。Git _gitUri 应用主机规范化，失败统一为 Invalid Git URL；strip 保留非法输入，derive 返回 null。Node 对照 127.1、0x7f.1、0177.0.0.1、2130706433、1.2.65535 和尾点，另核对 256 段/09 八进制/2^32 越界。Git 专项 28 项、严格静态分析通过；最后完整回归仍为 1349 项。仍需 IDNA、百分号 host 解码和完整 WHATWG URL 语料验证，不能认定 host 全等价。

### Git HTTP 主机百分号解码（2026-10-12）

HTTP(S) _gitUri 在 IPv4-number 解析前对 host 执行 UTF-8 百分号解码，并拒绝 special host 禁止字符（控制字符、空格、#、%、斜线等）；非法 UTF-8 同样转 Invalid Git URL。新增 %65xample.test、%31%32%37.1、IPv6 不受影响及五种非法编码主机回归，分别验证 withCredentials 拒绝、strip 保留原输入、derive 返回 null。Git 专项 29 项、严格静态分析通过。最新完整回归 1353 项通过，包含近期全部 URL/IPv4/凭据语料。IDNA 与完整路径/query/fragment 序列化仍未完成。

### Numeric host 差分语料及 IPv6 区分（2026-10-12）

新增 tool/generate_ipv4_vectors.js，固定 xorshift 生成 1024 个十进制/八进制/十六进制混合段数及尾点组合，加 7 个边界，保存 1031 项 Node URL hostname/失败结果。Dart 通过 withGitCredentials 比较成功规范化地址或 InvalidArgumentException，全部一致。另将 forbidden-host 校验的 IPv6 判断改为原始 authority 的方括号，而不是解码后的冒号，拒绝编码冒号及编码方括号伪装 IPv6，保留合法 [::1]。Git 专项 30 项、严格静态分析通过；最后全套仍为 1353 项。IDNA 与完整 WHATWG 路径/query/fragment 不在此语料范围内。

### SandboxPaginator 公开类型（2026-10-12）

新增命名 SandboxPaginator extends Paginator<SandboxInfo>，接收连接选项、分页游标及查询字段，复用既有 queryBuilder、错误转换与分页状态行为。E2BClient.listPaginator 和 E2B.Sandbox.list 返回具体类型；未注入 client 时使用逐页 ApiClient 工厂及 finally 关闭机制。绑定分页及 E2B 专项合计 22 项通过、严格静态分析通过。异构 snapshot/sandbox 测试显式声明共同 Paginator<dynamic>，避免 Dart 条件表达式推断 Object。完整直接构造和全部公开选项验收尚未完成，维持部分映射。累计 152 项部分映射、11 项待审计，最后全套 1353 项。

### SandboxPaginator 直接构造真实 HTTP（2026-10-12）

新增本地 HttpServer 集成测试，不注入 ApiClient/HTTP 客户端，直接构造 SandboxPaginator。验证初始游标/limit、服务端新游标、403 后游标保留和重试、逐页 apiKey 覆盖、状态数组修改在后续页生效，以及结束后拒绝调用且不发送新请求。该证据证明默认逐页客户端真实 HTTP 路径可用，客户端关闭机制仍由通用 Paginator 的独立生命周期测试提供证据，不把网络成功等同于所有资源释放验收。最新完整回归 1355 项与严格静态分析通过。真实 E2B 云端、全部选项及平台仍待验证。

### 分页 limit number 范围（2026-10-12）

通用 Paginator、SandboxPaginator、SecretPaginator、Sandbox/Secret/快照绑定与单页入口的 limit 由 int? 拓宽 num?，查询统一 jsNumberString。官方 limit:number 没有 SDK 整数/正数校验，Dart 同样把小数、负值、NaN 和 Infinity 原样发送，由服务端处理。新增三种资源矩阵，覆盖 0.5/-1.5/1.0/1e21/NaN/Infinity，验证整数 double 不带 .0、指数带 +。分页专项 12 项、严格静态分析通过；最后完整回归仍为 1355 项。Dart 扩展 listAll 的 pageSize 保留 int；它不是官方 API。尚未据此认定所有数值选项已对齐。

### Fork count Number.isInteger（2026-10-12）

官方 validateForkCount 要求 Number.isInteger 且 1..20。Dart fork 的 count 拓宽 num?，允许 1.0/20.0 等 JS 有效整数 double，同时显式拒绝小数、NaN、Infinity、零与越界，错误消息保持一致；HTTP body 在已验证范围内转 int，避免 .0。E2BClient、绑定 SandboxResource 与 Sandbox 实例入口同步拓宽。新增成功边界和六种失败输入，失败前不发送请求。管理/E2B 专项 39 项、严格静态分析通过；最后全套仍为 1355 项。该字段保留官方整数校验，与不做整数限制的分页 limit 区分。

### IPv4 空地址段边界（2026-10-12）

差分扩展发现 IPv4-number 函数把原始空字符串和移除 0x 前缀后为空混为一谈：官方前者失败，后者为零。新增入口空字符串检查，拒绝 1..2/.1，保留 '.'/'..' 非 numeric host 和 0x/0x.1/1.0x 的官方结果。Node corpus 增加六个边界，共 1037 项通过，Git 专项仍为 30 项（循环样本增加）。最新完整回归 1357 项、严格静态分析通过，覆盖最近分页 limit 与 Fork count 改动。IDNA/完整 URL 序列化及其他 SDK 模块审计继续保持未完成状态。

### Template 构造数组引用与凭据错误（2026-10-12）

核对 TemplateBase 构造器直接保存 options.fileIgnorePatterns，Dart 改为保留调用方 List 引用，构造后增删模式可被后续 COPY/hash/build 读取；移除 List.unmodifiable 复制。fromImage 凭据失败消息补齐官方 when providing registry credentials，五种空/缺失组合验证错误精确文本及 fromImage 状态不被修改。Template 专项 32 项、严格静态分析通过；最后全套仍为 1357 项。TemplateFromImage/Builder/Final 的阶段类型、TemplateBase 静态表面与 fileContextPath 默认调用方目录仍待完整对齐。

### GCP registry 失败状态顺序（2026-10-12）

官方 fromGCPRegistry 在读取 serviceAccountJSON 前更新 baseImage 并清除 baseTemplate，读取成功后才替换 registryConfig 和设置 force。Dart 原先先读文件，再调用 fromImage，失败时完全未变更基础来源。现按官方顺序拆开更新；文件读取失败后基础镜像已切换、旧 registry 保留、force 保持原值。新增不存在凭据文件回归，验证失败后的完整相关字段。Template 专项 33 项、严格静态分析通过；最后全套仍为 1357 项。错误堆栈、GCP 对象序列化全边界与阶段类型仍待审计。

### Template gitClone number 范围（2026-10-12）

模板 gitClone 与 sandbox.git.clone 是两个独立命令构建入口。核对官方模板 gitClone 的 depth:number truthiness 与模板字符串转换，Dart depth 拓宽 num?，省略 0/NaN，其他值使用 jsNumberString，避免 1.0 与指数表示差异。新增七种 depth 对照，并同时验证带空格 branch/path 的 shell 引用、--single-branch 顺序及 RUN args 中 user。Template 专项 34 项、严格静态分析通过；最后完整回归仍为 1357 项。包管理命令基本参数实现与官方逐段核对一致，但完整组合及类型仍需审计。

### 绑定 Template 序列化辅助入口（2026-10-12）

官方 callableTemplate 保留 TemplateBase.toJSON/toDockerfile 静态方法，Dart 原先仅顶层 Template 提供，client.Template 返回 Templates 时无法调用。新增 Templates.toJSON/toDockerfile 委托，保留 computeHashes 默认 true 与既有错误行为。新增方法提取后调用、无 API key/无 HTTP、JSON/Dockerfile 与顶层一致以及 fromTemplate 转 Dockerfile 错误传播回归。最新完整回归 1362 项、严格静态分析通过，包含近期全部 Template 引用、GCP 失败状态、gitClone 数值改动。此项只补齐绑定入口；序列化格式、文件哈希及完整静态类表面仍需独立审计。

### Dockerfile 导出错误与投影（2026-10-12）

核对官方 TemplateBase.toDockerfile：fromTemplate 失败为普通 Error，消息为两句完整说明；Dart 原先 TemplateException 与短消息不符。现使用共同 E2BException 表达普通错误并补齐精确消息，增加 baseImage 缺失保护。新增 ENV/WORKDIR/USER/RUN/ENTRYPOINT 完整文本回归，验证 RUN 不把 instruction user 参数输出为 Dockerfile 命令，fromTemplate 错误不属于 TemplateException。修正两处旧测试的异常层次预期。模板/E2B 专项 48 项、严格静态分析通过；最后全套仍为 1362 项。仅捕获 TemplateException 的调用方需要显式捕获共同基类；完整 COPY 与所有输入序列化仍需审计。

### Template JSON 本地文件读取时机（2026-10-12）

官方 instructionsWithHashes 仅在每条 COPY 分支读取 dockerignore。Dart toJSON(computeHashes:true) 原先无 COPY 也读取；现移动到 COPY hash 分支，computeHashes:false 继续完全跳过。用非法 UTF-8 .dockerignore 固定可观察读取副作用：无 COPY 成功，含 COPY 且 false 成功，实际 hash 才读取并触发当前解码异常。Template 专项 36 项、严格静态分析通过；最后全套 1362 项。另定位待修复差异：Node readFileSync utf8 替换损坏字节，而 Dart readAsStringSync 严格失败；上述测试仅证明读取时机，不证明文件解码已等价。

### 本地模板文本 Node UTF-8（2026-10-12）

新增 nodeUtf8Decode，损坏字节替换 U+FFFD 并保留输入 BOM，区别于 fetch TextDecoder 默认去除 BOM。本地 GCP/Dockerfile 文件和 dockerignore 改用 bytes 读取后该解码；dockerignore 再按官方显式去除一个前导 BOM。新增 GCP 文件包含 BOM、非法字节和截断 UTF-8 的 Node Buffer 对照，结果为 BOM+replacement+a+replacement。上一批 hashed COPY 测试更新为损坏 ignore 不再导致解码异常，后续缺失源文件仍抛 TemplateException。Template 专项 37 项、严格静态分析通过；最后全套仍为 1362 项。dockerignore 行 trim 字符集合与所有本地读取错误映射仍需审计。

### Dockerignore 文件行处理（2026-10-12）

readDockerignore 行 trim 改用 ECMAScript jsTrim，保留 U+0085，去除 BOM/U+2007 等官方空白。新增文件回归与 Node 官方处理链对照：先去一个前导 BOM，再过滤列零 # 注释，再 trim 和去空行，因此缩进 # 行仍保留在返回模式中。模板文件专项 11 项、最新完整回归 1366 项及严格静态分析通过，覆盖最近全部序列化/本地 UTF-8 改动。模式匹配器和 glob 转换仍有独立 trim/规则语义需对照各自 Node 库，不将文件行预处理结果推定为完整 ignore 等价。

### Ignore 模式两层 trim 对齐（2026-10-12）

核对官方 template/utils.ts normalizeIgnorePattern 与 dockerfile-utils-js/src/dockerignore.ts PatternMatcher，两层均使用 JS trim，否定前缀之后也 trim。Dart _normalizePatterns 与 DockerIgnoreMatcher 同步改用 jsTrim，避免 U+0085 模式被误丢弃或 !U+0085 被误判为非法空否定。新增普通/否定 U+0085、BOM 空模式/非法否定与 U+2007 包围模式；ignore/模板文件专项合计 207 项、严格静态分析通过。最后全套仍为 1366 项。该结果关闭已定位 trim 字符集合差异，Node glob 与全部路径/归档平台差异仍保持待审计。

### 近期跨平台复验（2026-10-12）

web_routing_smoke 新增 Git 十六进制短 IPv4 和 tracking NaN 断言；Dart JS 编译后 Node 执行通过，既有 Web Volume 缓冲上传检查同样通过。Dart 3.5.4 全套发现 limit 测试语料以 NaN 作 Map 键导致 entries 取值为空，改为顺序 MapEntry 列表，避免语料本身依赖 NaN 键查找。修复后 Dart 3.5.4 全套 1367 项通过，当前严格静态分析通过。该结果证明旧 VM 与非 IO 编译执行路径，仍不代替最低 3.4、真实浏览器网络、Windows 或 E2B 云端验收。

### 缺失 API key 提示（2026-10-12）

管理请求缺失 API key 的 AuthenticationException.message 对齐固定版本官方完整提示，包含 dashboard 地址、环境变量及 Sandbox.create 示例。新增回归验证空 key 在 HTTP 发送前失败，同时逐次 RequestOptions.apiKey 可以提供有效凭据。API 专项 14 项通过，严格静态分析通过。官方低层 ApiClient 在构造时校验，Dart 共用客户端在请求时校验以支持逐次配置；这一触发时机差异仍未关闭，不能把文本一致认定为整个认证接口等价。最后完整回归仍为 Dart 3.5.4 的 1367 项。

### 低层 ApiClient 构造认证开关（2026-10-12）

低层 ApiClient 新增官方 requireApiKey（默认 true），缺失 key 时同步构造失败；false 时允许无 key 请求且省略 X-API-Key，与官方条件 headers 对齐。Dart 扩展 deferApiKeyValidation 仅延迟校验至请求，用于 E2BClient、Secret 静态工厂及默认分页工厂在解析逐次 RequestOptions 后校验；不等同于关闭认证检查。构造失败关闭自行创建的池，不关闭调用方提供的 HTTP client/池。新增默认同步失败、显式禁用后无 key 请求测试，保留延迟失败及逐次 key 成功测试。Dart 3.11.3 全套 1369 项、静态分析通过。上一记录的默认低层校验时机差异已修复；官方 ApiClient.api 的生成客户端表面及其他低层选项仍未完整映射，导出审计状态保持待审计。

### retries 的 JS number 整数范围（2026-10-12）

官方 resolveRetries 使用 Number.isInteger 与非负校验，不限制为安全整数。ConnectionConfig、RequestOptions、ApiClient 及继承绑定入口的 retries 拓宽为 num，保留 0.0/1.0/1e21 等整数值，拒绝负数、小数、NaN 和正负 Infinity。错误精确对齐 Invalid retries=<JS number>: expected a non-negative integer.，使用共用 jsNumberString 避免 Dart 的 .0/Infinity 文本差异。新增配置、逐次选项和 E2B 三入口数值矩阵。Dart 3.11.3 全套 1370 项、严格静态分析通过。RequestOptions 的构造时校验是现有 Dart 扩展行为，官方纯 options 对象在 ConnectionConfig 解析时才校验；此时机仍不算等价。HttpVersion 配置和实际 HTTP/2 传输继续待实现/验收，不因本批数值校验关闭该缺口。

### 逐次 retries 校验时机（2026-10-12）

移除 RequestOptions 普通存储对象对 retries 的提前校验；merge 同样只保存选项。将官方 resolveRetries 规则抽取到内部 retry_config.dart，ConnectionConfig 解析时与 ApiClient 请求构建时统一使用，后者在认证、取消、池选择和 HTTP 发送前执行。更新负数、小数、NaN/Infinity 矩阵，证明选项可以构造及合并，而实际请求和 withOptions 配置解析精确报错且无 HTTP。API 专项 16 项与静态分析通过，Dart 3.5.4 全套 1370 项通过，覆盖近期构造认证及 num retries 改动。上一批标注的 RequestOptions.retries 提前失败差异已关闭；E2B.fromOptions 的整体解析时机、负 requestTimeout 与 HttpVersion 尚需独立审计。

### HttpVersion 配置及环境解析（2026-10-12）

新增 HttpVersion 字符串别名和 resolveHttpVersion，精确接受 '1.1'/'2'，缺省读取 E2B_HTTP_VERSION，空环境变量回退 '2'，显式空值拒绝；错误保留 httpVersion/E2B_HTTP_VERSION 来源。RequestOptions/merge、ConnectionConfig、ApiClient、E2BClient/E2B 构造与派生及 Volume 创建/连接/内容选项新增继承路径。管理请求与 envd/content 的 httpClientFor 在选择客户端前校验非法值。新增显式输入矩阵、绑定/覆盖/Volume 属性和六次独立子进程环境验证；Dart 3.11.3 全套 1372 项通过，静态分析通过。HttpVersion 导出记部分映射，累计 153 项部分映射、10 项待审计。底层仍为 IOClient HTTP/1.1，没有 HTTP/2 ALPN、复用及按版本分池；本批不宣称 HTTP/2 支持，下一步接入支持 Dart 3.4 的原生传输并开展真实本地 TLS/多路复用/取消测试。

### 原生 HTTP/2 TLS 连接池基础（2026-10-12）

新增内部 Http2ConnectionPool，使用官方 http2 2.3.1（依赖声明 SDK ^3.2.0，不抬高项目 Dart 3.4 基线），按 HTTPS origin 共享正在建立/已建立的 TLS 连接，ALPN 提供 h2/http/1.1。协商非 h2 和 cleartext 返回 null 供后续 HTTP/1.1 适配器回退；失败清除缓存，连接终止清除对应 origin，关闭后拒绝新连接。真实本地 TLS 测试验证八个并发调用只建立一个 TCP/TLS 连接、八个不同 HTTP/2 stream 响应、HTTP/1.1 协商回退、关闭后拒绝，以及证书校验失败后加入测试信任可重新连接。三项专项在 Dart 3.11.3 与 3.5.4 均通过，静态分析通过；最后全套仍为 1372 项。本地 PEM 为测试专用 localhost 证书与无生产用途私钥，有效期至 2027-10-12，后续需改为测试时生成或长期可维护语料。此基础尚未接入 ApiClient/EnvdTransport/Volume，生产 SDK 仍 HTTP/1.1；请求适配器、gzip/redirect、取消、代理隧道及握手期间 close 尚未完成，不宣称 HTTP/2 已交付。

### HTTP/2 请求/响应流适配器基础（2026-10-12）

新增内部 Http2Client extends http.BaseClient，复用 TLS 连接池，构建 HTTP/2 pseudo headers、过滤 hop-by-hop headers、传送请求体、解析状态/响应 headers 并按消费需求读取 DATA；cleartext 或 ALPN 非 h2 委托 IOClient。取消在连接等待/响应头前/响应流中映射 RequestAbortedException，终止当前 stream；消费端主动取消同样发送 stream reset，不关闭共用连接。五项真实本地集成测试验证 POST UTF-8 字节和路径/query/自定义头、响应状态/头/体、响应头前取消后成功发送下一请求、响应流中途取消、消费端取消后服务端收到 reset 且下一请求成功、cleartext 回退。专项 5 项、严格静态分析通过；Dart 3.5.4 全套 1380 项通过，包含上批 TLS pool 三项。适配器尚未接入生产选择器，gzip/redirect、代理、写入背压、大流量、握手期间 close 和错误全边界待处理；不宣称完整 HTTP/2 支持。

### HTTP/2 gzip/deflate 响应与 Node 对照（2026-10-12）

内部 HTTP/2 适配器新增 gzip/x-gzip/deflate 流式解码，编码列表按逆序处理，HEAD/204/304 不执行解码。deflate 按首个非空块的首字节识别 zlib 包装或 raw deflate，不缓冲完整正文。保持 Node fetch 的原始 Content-Encoding/压缩 Content-Length headers。新增三字节分片、UTF-8 正文、大小写、叠加编码、raw deflate、损坏 gzip 后复用连接测试。保存 tool/http_compression_oracle.js（Node 22.21.1），七组真实本地 HTTP 对照发现 x-gzip 可解码、x-deflate 原样透传；修正最初把两者一概接受的实现，新增 x-deflate 原样测试。最终 Dart 3.11.3 HTTP/2 client 专项 9 项及静态分析通过；修正 x-deflate 前的 8 项曾在 Dart 3.5.4 通过，不作为最终九项旧版本验收。最后完整回归仍为 1380 项。Brotli、所有格式错误映射/空压缩体、取消与多层解码完整组合、重定向和代理仍待处理；生产选择器仍未切换。

### HTTP/2 重定向及未读响应释放（2026-10-12）

内部适配器新增 301/302/303/307/308 跳转：301/302 POST 和 303 非 GET/HEAD 转 GET 并移除请求体相关头，其他情况重放 http.Request 字节；无法重放的非空流式正文拒绝。支持相对 Location、followRedirects:false 与 maxRedirects，拒绝非 HTTP(S) 和含凭据的目标。跨 origin 移除 Authorization/Proxy-Authorization/Cookie/Host，保留 X-API-Key 等自定义头。新增响应流 guarded controller，未消费 DATA 即取消也能释放 HTTP/2 stream，用于不等待无界中间响应结束即可跳转。真实 TLS 测试覆盖五状态乘四方法的 20 组合、服务端收到 reset、手动模式、循环限额、跨来源凭据与自定义头。适配器专项最终 12 项及静态分析通过；最后完整回归仍为 1380 项。仍需 Node fetch 全矩阵对照、流式正文失败测试、跳转中的取消、fragment/URL 细节、HTTP/1.1 委托路径统一，以及 Fetch 默认 20 次与 BaseRequest 默认 5 次限额差异；本批不将重定向判为完整等价。Brotli、代理、写入背压、握手关闭及生产选择器继续待完成。

### Node Fetch 重定向语料与 SDK 默认限额（2026-10-12）

新增 tool/http_redirect_oracle.js，以真实本地 Node fetch 生成 test/http_redirect_vectors.json：五种状态乘 POST/PUT/PATCH/GET/HEAD，共 25 组参考方法与正文。Dart 原有 TLS 矩阵改为读取该语料，不再只比较自行计算的期待值；GET/HEAD 不携带正文以符合 Fetch 输入约束。新增 SDK ApiClient 注入内部 HTTP/2 客户端的真实 TLS 集成，连续 20 次重定向后成功取得 JSON，并验证共发送 21 次请求。管理、envd RPC、Volume 普通/流式内容构建请求统一 maxRedirects=20（http_defaults.dart），修复 Dart 默认 5 次与 Fetch 默认 20 次差异；直接使用内部 BaseClient 仍尊重调用方 BaseRequest.maxRedirects。适配器专项 13 项、Node 25 组语料及静态分析通过。HTTP/1.1 的方法/凭据处理仍由 IOClient 决定，不能把设置限额当成整个回退路径等价；流式正文拒绝、跳转取消、URL/fragment 细节、Brotli、代理及生产选择器仍待完成。

全量复验首轮出现环境变量子进程测试 30 秒超时，其余 1387 项通过。该测试串行启动六个独立 Dart VM；将其专属测试限额设为两分钟，保留全部输入和断言，不修改 SDK 请求超时或全局测试超时，并重新运行全量验证。

第二轮环境测试仍超时，证明仅延长限额不足以解决重复编译与进程清理问题。改为单次 dart compile kernel，再以同一个 kernel 启动六个独立 VM，保留环境隔离；每个子进程限额 60 秒且超时 kill，临时目录测试结束清理。API 专项在 Dart 3.5.4 下 18 项通过（11 秒），后续全套重新验证。

最终 Dart 3.5.4 全套 1388 项通过（59 秒），严格静态分析通过，覆盖本批跳转限额及最近所有 HTTP/2 基础、压缩和重定向改动。该结果不替代生产选择器、真实 E2B 云端和所有 Flutter/浏览器平台验收。

### 流式跳转拒绝顺序与跨跳转取消（2026-10-12）

Node fetch 实测发现，301/302 流式 POST 即便方法本可转 GET，仍先因不可重放正文失败；只有 303 可以丢弃流式正文并转 GET。Dart 原先先判断 dropBody，错误允许 301/302，现改为除 303 外先拒绝不可重放的流，包括显式 contentLength=0 的空 StreamedRequest。扩展 tool/http_redirect_oracle.js，生成 test/http_redirect_stream_vectors.json 的五状态乘空/非空流十组向量，真实 TLS 测试直接读取，失败仅一跳、303 成功两跳且目标方法/正文正确。另新增跳转后目标请求挂起时触发原 AbortableRequest 信号，证明取消仍生效、抛 RequestAbortedException 且共用连接上的后续请求成功。Dart 3.11.3 新增取消测试前 14 项通过，Dart 3.5.4 最终适配器 15 项通过，静态分析通过；最后全套仍为 1388 项。HTTP/1.1 回退方法/凭据、URL/fragment、Brotli、代理、握手关闭和生产选择器仍待完成。

### HTTP/1.1 回退共用 Fetch 跳转（2026-10-12）

HTTP/2 适配器回退分支原先直接 IOClient.send，导致其内部自动跳转绕过共同 Fetch 方法/正文/凭据规则。新增内部 _UnredirectedRequest，复制连接/请求属性、关闭单次 IO 自动跳转，finalize 委托原请求正文，Abortable 信号同样转发；不修改调用方 followRedirects。回退响应保留原单次 request 与 headers/body 元信息，由共用 send 循环决定下一跳。新增明文 HTTP 与只协商 HTTP/1.1 的真实本地 TLS 服务，各运行 25 组 Node 字节正文与十组 Node 空/非空流向量，共 70 个回退样本，最终目标方法/正文及流式失败一致。Dart 3.11.3 加流式语料前的 16 项通过，Dart 3.5.4 最终适配器 16 项通过，静态分析通过；最后完整回归仍 1388 项。回退协议跨来源凭据/取消仍需独立实测，压缩、URL/fragment、代理、握手关闭、生产选择器和完整平台验收继续未完成。

### HTTP/1.1 回退取消与凭据实测（2026-10-12）

新增明文及 TLS HTTP/1.1 四个取消场景（响应头前/首块正文后），逐块确认首块内容，原 AbortableRequest 信号仍返回 RequestAbortedException，后续请求成功。新增两种协议乘同/跨 origin 四组凭据验证：同来源保留 Authorization/Cookie/Proxy-Authorization，跨来源移除，X-API-Key 自定义头仍保留。初始测试使用缓冲小块输出及 map/drain 观察，等待首块失败；显式关闭测试服务端 bufferOutput 并改 StreamIterator 后通过。曾尝试不等待订阅取消的补丁已撤回，保留既有 IOClient 取消转发，不把测试观察问题当成 SDK 根因或制造新生产语义。最终证据不涵盖消费暂停、握手中关闭、全部 IO 网络故障，也不替代生产 HTTP/2 默认选择和云端验收。

Dart 3.5.4 最终适配器 18 项通过，严格静态分析通过；最后全套仍为 1388 项，未把本批新增两项计入已验证全套总数。

### HTTP/2 握手中关闭与原始 TLS 通道（2026-10-12）

连接池由 SecureSocket.connect 改为 RawSocket.startConnect 后 RawSecureSocket.secure，在握手成功前保留可关闭的 TCP 句柄，追踪 TCP ConnectionTask 与握手 socket。close 同时发出显式关闭信号、取消 TCP 建连、关闭握手 socket 和终止已建传输，并缓存关闭 Future 保证重复关闭共享完成结果。实测发现仅 raw.close 虽关闭 FD，但 Dart TLS 握手 Future 不自行结束；connect/握手等待增加关闭信号 race，调用者立即收到 StateError，底层连接仍实际关闭。新增 RawTlsChannel 用字节流/IOSink 接入 HTTP/2 transport，读暂停/恢复反映到 readEventsEnabled，写零字节时等待 writable 事件。真实本地服务仅接受 TCP、收到 ClientHello 后永不回应；测试验证 close 完成、连接 Future 失败、服务端 EOF 和关闭后拒绝新连接。新关闭专项通过，切换原始通道后既有 21 项连接/适配器测试通过，严格静态分析通过。DNS 阶段、关闭与成功竞态、超大写入背压、单请求取消时握手池生命周期仍需独立验证；不据此认定整个 HTTP/2 连接生命周期审计完成。

最终 Dart 3.5.4 全套 1394 项通过，覆盖最近增加的 HTTP/1.1 凭据/取消及本批 TLS 关闭和原始通道；静态分析通过。生产默认 HTTP/2 切换、Brotli、代理和完整公开面/平台/云端验收仍未完成。

### HTTP/2 多 MiB Node 互操作及 Dart 对端超时保留（2026-10-12）

新增三条并发 stream，各 1/2/3 MiB+17 字节，经原始 TLS 通道上传并完整回传，验证响应长度和 SHA-256，覆盖多次 HTTP/2 流量窗口更新。最初 Dart ServerTransportConnection 对端在 30 秒内未完成，字节计数显示仍推进；原生 SecureSocket 基线同样失败，TCP_NODELAY 和改用非逐块暂停消费者均未单独关闭该问题。客户端新增 TCP_NODELAY 低延迟设置，但不能据此宣称修复 Dart 对端超时。最终默认使用 Node 原生 HTTP/2 echo 对端，同样数据量和并发约五秒通过。保留 tool/http2_dart_echo_peer.dart 与 E2B_TEST_HTTP2_PEER=dart 选择器，便于继续复现未定位问题，不把失败对端从证据记录中删除。Node 对端位于 test/fixtures/http2_echo_server.js；测试启动/结束管理独立进程。Dart 3.11.3 Node 大数据专项通过，Dart 3.5.4 连接池+适配器合计 23 项通过，选择器默认路径专项复验通过，严格静态分析通过；最后全套仍为 1394 项。该证据证明 Node 互操作和数据完整性，不证明有界内存、全部慢消费者或所有对端性能；Dart 对端超时、Brotli、代理及生产默认选择仍待完成。

### GOAWAY 重连、排空与迟到缓存清理（2026-10-12）

connect 现在检查已缓存连接 isOpen，GOAWAY/不可开新 stream 时撤销该 origin 当前映射并共享新的建连 Future，不终止仍有旧 stream 的连接。新增 origin→connection 身份映射；旧连接结束仅在仍是当前 origin 身份时移除缓存，避免迟到 EOF 删除新连接。源码审计发现 http2 2.3.1 的 onFrameReceived 控制器不关闭，原 onDone 清理不可依赖；RawTlsChannel 新增实际 TLS 结束 Future，由 readClosed/closed/error/主动 close 完成，连接池据此释放记录与通道。Node 真实 TLS 用例保持旧响应打开，发送 GOAWAY，新请求使用 session 2，再排空旧响应并让服务端显式关闭旧 session，确认后续仍复用 session 2。两个临时负向对照均按预期失败：删除 isOpen 检查复用 finishing 连接报错；删除身份判断导致 session 3，证明测试能捕获对应回归。临时代码自动恢复，最终修复用例与静态分析通过。GOAWAY 与新请求精确同时发生的重试、并发流/连接上限、空闲 GOAWAY 主动关闭及完整故障组合仍需验收；不据此宣称整个连接池已等价。

最终 Dart 3.5.4 全套 1396 项通过，严格静态分析通过，包含 Node 多 MiB 互操作及本批 GOAWAY 生命周期修正。Dart 诊断对端超时仍保留未解决状态；生产默认 HTTP/2、Brotli、代理和完整 SDK/平台/云端验收仍待完成。

### Brotli 增量解码要求及依赖审查（2026-10-12）

tool/http_compression_oracle.js 新增 br、BR、gzip 后 br 三组真实 Node Fetch 对照，均成功解码且保留原压缩头。新增握手式流测试：服务端 Brotli FLUSH 前缀后等待客户端读取，客户端读到前缀才允许服务端写尾部并结束；五秒 AbortSignal 防止整包缓存实现无限挂起。Node 22.21.1 十组普通压缩对照及该增量输出对照通过。该脚本是 Node 行为基准，尚非 Dart Brotli 验收。

下载并检查 brotli 0.6.0 发布源码：pubspec SDK >=2.14.0 <3.0.0，不符合本项目 Dart >=3.4；lib/src/decoder/decode.dart 的 _BrotliSink.add 只累积 BytesBuilder，close 才调用 _decodeToSink，所谓 chunked API 不提供 EOF 前输出。故未新增该依赖，也未用整包缓存替代官方流式语义。后续需实现或选用兼容最低 Dart 的增量解码器，补齐取消、损坏输入、堆叠及慢消费者验证。最后 Dart 完整回归保持 1396 项，本批只修改参考脚本及记录。

### 默认原生 HTTP/2 接入及协议缓存（2026-10-12）

原生无代理且 httpVersion=2 时 createHttpClient 现在创建 Http2Client，1.1 仍为 IOClient；ApiClient.httpClient 与 httpClientFor 将配置/逐次版本交给连接池。池按 version:proxy 缓存并延迟创建自有客户端，关闭全部自有实例；显式注入客户端对初始 proxy 的两个版本均保持权威且不被池关闭。浏览器继续使用宿主传输。新增三个连接池/选择测试，覆盖协议实例、缓存复用、代理隔离、关闭、逐次覆盖和注入所有权。新增默认 ApiClient 无注入真实 TLS 测试，测试进程信任本地证书后与仅 h2 的服务端通信，验证路径、API key 和 JSON 返回；不将只检查实例类型当成实际协议协商证明。

Dart 3.5.4 最终全套 1400 项通过；当前 Dart 严格静态分析通过；web_routing_smoke 编译为 JS 并在 Node 下运行通过（不代表真实浏览器网络验收）。本次默认切换仅落实直连路径，代理请求仍由 IOClient 使用 HTTP/1.1，不能宣称代理 HTTP/2 已完成。Brotli、并发连接/请求上限、Dart 诊断对端大数据超时、完整连接故障、Flutter/浏览器/云端验收仍未关闭。

### HTTP/2 请求 FIFO 限流（2026-10-12）

依据固定官方 api/inflight.ts，新增 HttpRequestLimiter：FIFO 槽位、排队 Abortable 信号移除、预取消拒绝、发送失败 finally 释放、关闭拒绝未派发请求；响应头 Future 完成即释放，不延长到正文消费结束。Http2Client.send 在整个跳转过程外使用该限制，默认 1000，可通过内部构造参数 maxInFlight 调整，0 禁用。同一适配器的 ALPN/明文回退也经过限制。新增三项行为测试分别覆盖队列顺序及未消费正文、排队取消和错误释放、预取消/关闭/禁用。首轮测试清理 await 未订阅 StreamController.close 导致超时，修正为断言完成后订阅 drain 再关闭；未修改生产释放时机来迁就测试。

Dart 3.5.4 全套 1403 项通过，静态分析通过。该批不是完整 dispatcher 等价：尚未读取 E2B_API_INFLIGHT_REQUESTS，独立 HTTP/1.1 与代理 IOClient 未接入限制，E2B_API_CONNECTIONS 连接上限及 envd 独立并发策略待审计。上次默认路由接入已完成直连 HTTP/2，此处继续保留其 Brotli/代理及平台云端验收缺口。

### 原生并发环境配置与 HTTP/1.1/代理限流（2026-10-12）

新增 http_dispatch_config.dart，读取 E2B_API_INFLIGHT_REQUESTS，未设置/空为 1000，0 禁用；使用 ECMAScript 空白和十进制 parseInt 前缀规则（1.9→1、1e3→1、0x10→0），保留 binary64 舍入与负值/非法值官方消息。限流阈值使用 num，避免把合法 JS 大数截成原生 int。Http2Client 默认读取配置；原生 HTTP/1.1 与代理工厂使用继承 IOClient 的内部限流客户端，保持 IOStreamedResponse 类型、代理认证及连接关闭。显式注入客户端仍由调用者控制。

新增配置边界测试；tool/http_inflight_smoke.dart 使用真实本地 HTTP 服务及代理，独立进程分别设置环境变量为 1/0，确认第二请求排队/并发及最终两个请求完成。两种配置、两个路由均通过。Dart 3.5.4 完整回归 1404 项通过，静态分析通过。浏览器工厂尚未加入同样限制，envd 独立的环境变量/默认策略尚未审计，API 连接上限亦未实现；不能据本批认定整个 dispatcher 等价。

### envd REST/RPC 独立传输作用域（2026-10-12）

核对固定 envd/http2.ts：REST 与 RPC 使用不同 fetcher Map，默认各 2000，变量分别为 E2B_ENVD_INFLIGHT_REQUESTS / E2B_ENVD_RPC_INFLIGHT_REQUESTS。新增 HttpDispatchScope，连接池缓存键增加 api/envdRest/envdRpc，默认配置分别 1000/2000/2000；原生工厂接收明确 maxInFlight。Sandbox 的 Connect/命令使用 RPC 客户端，文件内容、健康检查及普通 REST 请求使用独立 restClient；withOptions 分别解析对应客户端。显式注入客户端保留全部作用域的调用者控制。新增池身份、默认配置及逐次版本继承测试。

首轮全套发现手工构造 EnvdTransport 仅设置旧 clientResolver 时，文件逐次调用错误保留原客户端；修正为未配置独立 REST 客户端/resolver 时跟随 resolvedClient，已有上传/下载测试恢复通过。最终 Dart 3.5.4 全套 1405 项通过，严格静态分析通过。官方缓存为模块级全进程共享，当前池仍随根客户端共享，独立根客户端之间尚未全局限流；浏览器路径、连接数量限制、真实 envd 服务及完整并发取消组合仍待验证。

### HTTP/1.1 连接上限与浏览器策略纠正（2026-10-12）

进一步检查固定 undici.ts 的 createRuntimeFetch，非 node 直接 lateBoundGlobalFetch，不调用 buildDispatchedFetch。因此此前记录的“浏览器限流待实现”不是官方等价要求，现纠正：浏览器工厂继续委托宿主客户端，池不读取原生 dispatcher 的并发/连接配置。新增连接配置解析：E2B_API_CONNECTIONS 默认 100，envd REST 固定 10，E2B_ENVD_RPC_CONNECTIONS 默认 200；正整数检查保留 JS parseInt 前缀及官方错误文本。原生 IOClient 的 HttpClient.maxConnectionsPerHost 应用对应限制，Http2Client 的 HTTP/1.1 回退同样应用。

配置专项覆盖默认、前缀、小数、指数与零/负数/非法值；真实 HTTP/代理 smoke 在 E2B_API_INFLIGHT_REQUESTS=0、E2B_API_CONNECTIONS=1 下确认第二请求受连接上限阻挡，放开首请求后完成。Dart 3.5.4 全套 1406 项、静态分析及 Web 编译运行通过。本批尚未实现 HTTP/2 多连接调度及 peer 最大 stream 限制；极大 JS 数值转原生 int 的资源配置范围、代理多 origin 记账及独立根客户端的全进程共享仍需审计。Web Node smoke 不是浏览器真实网络验收。

### HTTP/2 初始 SETTINGS 门槛（2026-10-12）

连接池此前 TLS ALPN 完成即返回 transport，而底层库明确不等待初始 SETTINGS；客户端可能在 peer 的并发限制应用前发请求。现在 _connect 等待 onInitialPeerSettingsReceived，并同时观察 TLS EOF 与池关闭以拒绝无限等待。新增真实 TLS 测试延迟创建服务端 transport，证明连接 Future 不提前完成；随后发送 concurrentStreamLimit=1，打开一个 stream 后 isOpen=false，证明限制已应用。另测 TLS 成功但永不发 SETTINGS 时 pool.close 和 pending connect 在三秒内终止。最终 Dart 3.5.4 全套 1408 项通过，静态分析通过。

源码审计同时发现 http2 2.3.1 的 ClientConnection.isOpen 合并 finishing/terminated 与 _streams.canOpenStream；当前池对 !isOpen 统一重连，会把暂时 stream 饱和误判为失效，尚无每 origin 多连接总量约束。该发现改变下一步实现方向：必须区分 GOAWAY 与容量状态、原子分配 stream，并按连接上限排队；不能以初始 SETTINGS 门槛认定全部并发限制完成。

### HTTP/2 有界容量调度及原子 stream 分配（2026-10-12）

生产适配器从 connect 后独立 makeRequest 改为池内原子分配：每 origin 串行进入分配操作，检查现有非 draining 连接 isOpen 后立即 makeRequest；容量不足时在配置连接上限内建连，上限已满则等待帧/active 状态/TLS EOF/取消/关闭事件。新增 Http2FrameObserver，只保存九字节帧头并跳过 payload，识别 stream 0 GOAWAY；其余协议验证仍由底层库执行。GOAWAY 连接从可分配容量中排除，保留旧 stream 排空；暂时 stream 饱和保留连接等容量恢复。原先 connect 把所有 !isOpen 当失效的判断已改为明确 draining 状态。修正多连接时旧 pending GOAWAY 与最新 origin 身份不同可能递归复用旧 Future 的情况。

makeRequest 支持排队取消；已分配但尚未交回调用者的 stream 也由取消回调终止，避免分配/取消竞态泄漏。适配器正文结束/取消通知池容量，h1 回退与 h2 使用同一配置连接上限。新增服务端 concurrentStreamLimit=1 的真实 TLS 两组测试，分别将池连接上限设为 1/2，填满后取消一个等待者，并同时排四个新请求；首个 stream 结束后全部在原连接数量内完成。帧观察器对所有 chunk size 测试，确保 payload 中伪 GOAWAY 字节不被误读。Node GOAWAY 测试现在将连接上限设为 1，验证 draining 旧连接不阻止替换及迟到 EOF 不污染缓存。临时删除容量判断的负向对照两组均失败（等待请求提前派发），自动恢复源码。

最终 Dart 3.5.4 全套 1411 项通过，严格静态分析通过。证据尚未覆盖动态 SETTINGS 升降/零容量、精确同时断连和 makeRequest、全部错误恢复、连接上限跨根客户端共享及有界请求正文内存；这些仍需后续验收。Brotli、代理 HTTP/2、Dart 诊断对端吞吐以及完整平台云端验证仍未关闭。

### 动态 SETTINGS 零容量与恢复验收（2026-10-12）

新增 test/fixtures/http2_settings_server.js，Node TLS 对端初始 maxConcurrentStreams=0，并通过 stdin 控制 SETTINGS 变化；stdout localSettings 事件确认对端收到 ACK，避免仅凭发送时间猜测客户端已应用。适配器新增真实协议测试：初始 0 保持请求等待；升至 1 后返回；持有一条已收到前缀的流时降至 0，旧响应仍能结束，但等待新请求不因旧流结束绕过零容量；再次升至 1 后完成，响应报告始终只有一个 session。最后设 0 验证排队 AbortableRequest 取消及 client.close 拒绝未派发请求。恢复/取消/关闭设三秒限额防止无限挂起。

负向对照临时移除 onFrameReceived 容量唤醒，测试在初次恢复时三秒超时失败；源码通过 finally 恢复。最终 Dart 3.5.4 全套 1412 项通过，严格静态分析通过。此测试证明所列零容量/升降场景，尚不覆盖多连接不同 SETTINGS 的完整组合、SETTINGS 与 GOAWAY/断连同时发生、全部连接资源回收及跨根客户端共享，传输模块仍为 L2。

### 独立根客户端共享传输与关闭引用（2026-10-12）

HttpClientPool 新增 isolate 内静态传输注册表，键为作用域/HTTP 版本/代理；每个根池首次获取时取得一个引用，重复获取不重复计数。根池 close 仅释放自己的引用，最后引用释放才移除注册项并关闭传输；手工注入客户端继续独立且不由 SDK 关闭。这样同时存活并使用相同配置的独立根客户端实际共享连接上限和请求槽位，仍按每条请求添加各自凭据。

新增真实 HTTP 所有权测试：两个根客户端共享三种作用域；关闭第一个后第二个可请求，重复 close 不多减引用；最后引用关闭后新根池得到新传输。tool/http_shared_dispatch_smoke.dart 在三个 INFLIGHT_REQUESTS 均为 1 的独立进程运行，三个作用域均验证跨根客户端排队，持有请求期间关闭一个根池不打断另一个，释放后完成。新增默认 ApiClient 真实 TLS h2 测试，两根客户端先后收到 stream ID 1/3，关闭第一个后第二个收到 5，证明同一个会话持续复用，且请求 key 顺序为 first/second/second。

最终 Dart 3.5.4 全套 1414 项、严格静态分析通过；Web 编译及路由 smoke 运行通过。共享边界为 Dart isolate，无法跨 isolate 共享 socket；最后引用时主动关闭是 Dart close 扩展生命周期，官方模块级缓存没有该显式释放入口。跨 isolate 策略、全部中途关闭/获取竞态及浏览器真实网络仍待验收，不将本批视为整个传输等价审计完成。

### HTTP 代理 CONNECT 与 HTTP/2 接入（2026-10-12）

Http2ConnectionPool 支持 HTTP proxy：先连代理，在保留原始 socket 的阶段发送 CONNECT authority，成功后使用同一个 RawSocket/subscription 升级 TLS，SNI 与证书验证指向目标 host，ALPN 继续协商 h2/http1.1。CONNECT 写入处理 partial write，读取分片响应头，失败状态/EOF 拒绝；池关闭同时打断 CONNECT 等待和实际 socket。URI 用户信息解码后仅用于 CONNECT Basic 头。生产工厂现在在配置 HTTP/2 的代理路径使用该适配器；明文目标仍使用现有 IO 回退。

新增 Node 代理/目标服务及五项集成测试：h2/h1 两种目标乘匿名/认证，验证实际返回协议、h2 两次请求仅一个隧道、目标未收到代理认证头，错误密码得到 CONNECT 407 拒绝；默认 ApiClient 同样经代理及重定向取得正确结果。另测代理收到 CONNECT 后永不回答，client.close 后请求和代理 EOF 三秒内完成。

首轮 h1 认证用例实际发现 Proxy-Authorization 到达目标。审查 dart:io 显示缓存代理凭据会添加到 origin request；新增完整 HttpClient 委托包装，在 openUrl 返回目标 HTTPS 请求时移除该自动头，保留内部 CONNECT 认证。显式 HTTP/1.1 代理路径使用 allowH2=false 的共用适配器，逐跳禁用原生自动重定向并清理凭据。重定向集成验证目标仍无代理认证头。曾按未经证明的 h1 keep-alive 假设期待固定隧道数，实测不同请求新增隧道，撤销该断言，保留实际协议和认证边界验证；不宣称 h1 代理隧道复用完全等价。

最终 Dart 3.5.4 全套 1419 项通过，严格静态分析通过。HTTPS 代理服务器仍不支持；官方 proxyTunnel=true 对明文目标的隧道策略尚未对齐；CONNECT 响应头全边界/中途取消、h1 隧道连接记账及复用、Brotli、全部平台云端验收仍待完成。本批是 HTTP 代理至 HTTPS 目标的 h2 能力及认证边界修复，不能扩大为整个代理模块等价。

### HTTPS 代理双层 TLS（2026-10-12）

代理 URI 现在接受 http/https。HTTP/2 池连接 HTTPS 代理后，先对代理 hostname 建立 TLS（ALPN http/1.1），通过加密连接执行 CONNECT，再在原 RawSecureSocket 及已存在 subscription 上针对目标 hostname 建立第二层 TLS并协商 h2/http1.1。握手跟踪保留原始 socket 和外层 TLS，close 同时中断两层。原生 h1 回退通过 HttpClient.connectionFactory 对代理使用 SecureSocket.startConnect，内部 CONNECT 后继续目标 TLS；继续清理自动附加的 origin 代理认证头。缺省代理端口使用 URI scheme 的 80/443。

Node 代理 fixture 扩展 HTTPS 模式。测试矩阵为 HTTP/HTTPS 代理 × h2/h1 目标 × 匿名/Basic，共八项，涵盖真实目标协议、h2 隧道复用、默认 ApiClient 及显式 h1 代理重定向、凭据不泄漏和错误密码 407。新增独立代理证书/测试私钥（localhost/127.0.0.1，仅本地 fixture，2027-10-12 到期），目标继续使用原证书；HTTPS 每组分别测试不信任任一证书、只信任目标、只信任代理均抛 HandshakeException，只有同时信任两者成功。扩展 CONNECT 永不回应测试至 HTTPS，验证 close 后请求三秒内终止且代理观察 EOF。初轮错误密码测试忘记信任新代理证书，先得到 TLS 错误而非 407；修正测试信任配置，保留 TLS 与认证各自严格错误断言。

最终 Dart 3.5.4 全套 1424 项、严格静态分析通过。该结果关闭 HTTPS 代理至 HTTPS 目标的基本能力缺口，但不证明所有代理语义等价：明文目标的 CONNECT 策略、h1 隧道复用/记账、双层 TLS 全失败/取消组合、CONNECT 响应解析边界、Brotli 及各 Flutter/浏览器/云端真实验收仍需完成。

### 明文目标的 CONNECT 隧道（2026-10-12）

原生代理对 http 目标由正向代理请求改为 CONNECT：HttpClient 以 DIRECT 进行 origin HTTP 编码，connectionFactory 返回先连接 HTTP/HTTPS 代理、通过 CONNECT 后接管的 _PlainProxySocket。包装保留既有 socket 订阅、头后字节和流 pause/resume，将 IOSink/选项/地址操作委托原连接；仅用于明文 HTTP，不用于 SDK 私有 TLS detach 接口。ConnectionTask.fromSocket 支持取消 TCP/TLS/CONNECT 建连并销毁句柄。解析/凭据拆入 proxy_config.dart，避免连接实现循环依赖；两种 CONNECT 解析路径都检查含终止符的大头长度，修复超限头在同块结束时漏过限制。

Node fixture 现在拒绝普通正向代理请求，新增明文目标模式；HTTP/HTTPS 代理 × h2/h1/明文目标 × 匿名/Basic 共十二组验证，覆盖默认 ApiClient 与重定向、407、凭据未传入目标。四组明文场景另以 256 KiB+17 字节 StreamedRequest 上传，校验长度及 SHA-256；逐块读取响应前缀后取消，抛 RequestAbortedException，后续请求成功。HTTPS 代理至明文目标仅校验代理证书，修正测试中原本误要求目标 TLS 的断言。既有 Sandbox/Volume/逐次代理继承测试 fixture 改为真实 CONNECT 转发，继续保留请求路径、认证及继承断言，不把正常正向代理实现当成官方 tunnel 证据。限流 smoke 同步更新并通过。

新增明文 CONNECT 等待阶段取消用例，发现 _fallback.send 的 openUrl 等待先于 IOClient 安装取消处理；适配器改为将 fallback Future 与原 abort 信号竞速，调用者及时收到 RequestAbortedException。取消后 client.close 验证代理 EOF；单请求取消是否立即清理底层共享建连仍未证明，后续应补齐独立资源生命周期，不能将及时返回当成 socket 已释放。最终 Dart 3.5.4 全套 1429 项、严格静态分析通过。代理全解析边界/失败组合、h1 隧道复用记账、Brotli 和完整平台云端验收仍待完成。

### 明文 CONNECT 取消释放与队列隔离（2026-10-12）

将请求 Abortable 信号传入 plainProxyConnection 的 ConnectionTask；取消仅在 TCP/TLS/CONNECT 尚未完成期间生效，终止 task 并销毁 socket，连接已交给 HTTP 层后由既有请求取消机制管理。fallback.send 使用请求局部 Zone 传递信号至 openUrl；nativeHttpClient 显式登记 URI 请求上下文并在 connectionFactory 领取，而不是直接读取队列唤醒时的 Zone。

真实测试 HTTP/HTTPS 两种代理均在连接上限 1 下，让首个 CONNECT 永不回答；同 URI 第二请求在取消前已排队。取消首请求后调用者收到 RequestAbortedException，代理在 client.close 之前三秒内观察 EOF，第二 CONNECT 和 GET /next 完成。首个仅使用 Zone 的实现让第二请求继承已取消信号，实际返回 Connection attempt cancelled；查阅 Dart _ConnectionTarget._checkPending 证实排队 closure 在释放请求的 Zone 被调用，修正为显式票据领取。立即建连用确切票据，队列回调发现旧票据已领取/移除时领取相同 URI 下一请求，避免 idle 与新建请求混用信号。

负向对照移除 task.cancel 订阅，两组 EOF 断言均三秒超时失败，六秒内正常退出；源码 finally 恢复。首次负向运行曾因测试预先注册的第二请求异步 expectation 导致失败清理拖延并被 45 秒终止，已修正测试观察方式，让失败分支及时结束，不修改生产语义规避断言。最终 Dart 3.5.4 全套 1430 项、严格静态分析通过。证据只覆盖明文目标 CONNECT 等待，HTTPS 目标共享 TLS/CONNECT 的逐请求取消、所有 idle/新建/排队组合及关闭竞争仍需验收；Brotli 和完整跨平台云端验收仍未关闭。


### 明文代理完成后取消与空闲复用（2026-10-12）

在 HTTP/HTTPS 代理及匿名/Basic 四种组合中，让带 Abortable 信号的首个请求创建隧道并完整消费响应，随后触发该信号，再发送请求；通过代理真实 CONNECT 计数证明仍复用同一隧道。首次测试放在普通 GET 后，实际复用了无取消信号的既有连接，负向对照未失败；已将测试前移到首次建连，避免无效证据。

临时删除 plainProxyConnection 的 !pending 保护后，四组均因 CONNECT 计数从 1 增至 2 失败；finally 恢复生产源码。恢复后代理专项 16 项及严格静态分析通过，最近完整回归仍为 1430 项，本批没有重新运行全套。此证据仅证明完整消费响应后触发旧信号不会破坏空闲连接；其他请求正在复用时取消旧信号、HTTPS 目标共享握手取消及所有队列竞争仍需继续验证。


### 明文代理旧取消信号与活动响应隔离（2026-10-12）

每个代理/认证组合使用独立 Http2Client、连接上限 1，让带取消信号的首请求创建隧道并完整消费响应，再通过同一连接请求 /held。Node 夹具先发送 prefix，客户端确认收到后触发旧信号，再以 stdin release 控制服务端发送 suffix；响应正常结束，之后 GET 的真实 CONNECT 计数保持不变。覆盖 HTTP/HTTPS 代理 × 匿名/Basic 四种组合。

负向对照临时删除 !pending 保护并跳过前置空闲取消断言，确保故障发生在活动响应：四组均报告 Connection closed while receiving data，控制程序 finally 恢复生产与测试文件。正式源码全套 Dart 3.5.4 1430 项、严格静态分析通过（在负向运行前验证，恢复为同一内容）。尚未关闭 HTTPS 目标共享握手逐请求取消和全部队列竞争等剩余项，模块等级不提升。


### 初始 SETTINGS 等待阶段取消与队列隔离（2026-10-12）

新增真实 SecureServerSocket/HTTP2 协议回归，服务端完成 TLS 后暂不创建 HTTP2 transport，因此不发送初始 SETTINGS。首请求已进入建连，第二请求同 origin 排队，取消首请求后在三秒内收到 RequestAbortedException；随后服务端发送 SETTINGS，第二请求收到 ok，服务端路径列表仅 /survivor，TLS 连接数为 1。没有用定时延迟推测取消完成，先等待取消结果再放行 SETTINGS。

临时删除 makeRequest 在 await connect 后的 aborted 检查，负向对照明确捕获服务端路径 /canceled 与 /survivor（取消请求误派发）；finally 恢复源码。Dart 3.5.4 全套 1431 项通过，严格静态分析通过。该证据仅覆盖 TLS 已完成而 SETTINGS 未到达时的隔离，不证明 CONNECT/TLS 阶段独占请求取消会释放共享建连资源，仍需后续实现和验证。


### HTTPS HTTP/1.1 代理连接复用与 CONNECT 失败恢复（2026-10-12）

新增六组真实代理测试，HTTP/HTTPS 代理 × h2/h1/plain 目标，夹具首次 CONNECT 返回 503。首次请求抛 SocketException，随后同客户端相同 origin 两次请求成功，比较代理 CONNECT 计数要求恢复后的隧道复用。原实现两组 h1 测试明确失败，计数从 2 增至 3；其他四组通过。

检查 Dart 3.5.4 _ConnectionTarget.connect 与 _getConnection：原生 PROXY 建连以代理地址查找空闲连接，却将 TLS 隧道登记到目标地址，后续再次按代理地址查找而无法复用。新增 secure_proxy_socket_io.dart，由 SDK 使用真实 Socket/SecureSocket 完成 CONNECT，暂停代理响应订阅后调用 SecureSocket.secure 开始目标 TLS；将最终 TLS socket 作为 DIRECT connectionFactory 结果交给 HttpClient，以目标地址统一池键。代理 Basic 凭据仅写 CONNECT，不再配置原生代理认证缓存。沿用请求票据和待建连取消保护；支持 HTTP/HTTPS 代理独立信任链、64KiB 头限制及异常关闭。

原先失败的两组作为修复前对照，修复后六组均通过；全部代理专项 22 项，Dart 3.5.4 全套 1437 项及严格静态分析通过。尚有首次 h1 ALPN 探测再另建回退隧道、TLS 升级中取消的底层资源释放和全故障组合等差异，不能据此认定完整 dispatcher 等价。


### HTTPS 目标 h1 CONNECT 取消与排队恢复（2026-10-12）

新增 HTTP/HTTPS 两种真实代理，使用 allowH2=false、连接上限 1 验证新 secureProxyConnection 路径。首个 CONNECT 永不回复，第二个同 URI 请求先排队，再触发首请求取消。断言取消异常及时返回且代理三秒内观察 EOF（client.close 之前）；第二个代理连接返回 CONNECT 200 后使用 SecureSocket.secureServer 扮演目标 TLS，验证 GET /next 和完整 ok 响应，两个网络连接加一个升级 Socket，总计 3 个被跟踪对象。

移除 secureProxyConnection 的 task.cancel 订阅进行负向对照，两组 EOF 均在三秒超时；finally 恢复源码。最终 Dart 3.5.4 全套 1439 项及严格静态分析通过。此证据覆盖目标 TLS 尚未开始的 CONNECT 等待，不证明 SecureSocket.secure 已开始后的底层取消释放，也不覆盖 allowH2=true 共享池建连取消。


### HTTPS h1 目标 TLS 握手取消释放（2026-10-12）

将 CONNECT 取消测试扩展为 CONNECT/TLS 两阶段，TLS 阶段代理发送 200 后确认收到字节类型 22 的 ClientHello 记录，随后保持目标握手无回复。原 Socket/SecureSocket.secure 实现在 HTTP/HTTPS 代理两组中均未让代理观察 EOF，三秒超时；证明此前取消仅通知调用者，失去了升级中实际 raw 关闭句柄。

secureProxyConnection 改用 RawSocket，保留原 TCP、外层代理 TLS 和最终目标 TLS 的关闭句柄；CONNECT 复用 openHttpTunnel，目标 TLS 完成后以 RawTlsChannel 与实现 Socket 公开接口的适配器交给原生 HTTP 池。取消在 pending 期间关闭所有已获得的 raw 句柄，完成后旧信号不关闭复用连接。新的两个 TLS 阶段测试均验证 client.close 前 EOF 和同 URI 排队请求成功，原两个 CONNECT 阶段仍通过。

将代理矩阵内 256KiB+17 分块上传、SHA256 回显、前缀响应取消和后续恢复扩展到 h1 TLS 目标。首轮全套暴露另一关闭竞争：RawTlsChannel 在 EOF 已关闭 _input 后收到迟到 TLS 错误，addError 抛 Cannot add event after closing；添加 isClosed 守卫，数据投递同样保护。最终 Dart 3.5.4 全套 1441 项及严格静态分析通过。证据不包含 allowH2=true 共享建连取消、外层代理 TLS 阶段的所有竞争或跨平台运行，完整等价仍未完成。


### 共享 HTTP2 建连最后等待者取消（2026-10-12）

Http2ConnectionPool 对 makeRequest 分配阶段按 origin 计数，并跟踪每个正在建立的连接任务、raw 句柄和未完成 SETTINGS 的 transport。取消/完成分配只释放一次计数；仍有等待者时保留共享握手，最后等待者离开则取消未固定的建连、关闭 raw 句柄，并从可分配连接集合移除未完成 transport。显式 connect 调用固定共享任务，避免管理请求取消误伤独立连接使用者。失败 pending 缓存改为按 Future 身份清除，避免迟到错误删除新任务。

新增 TLS 与 HTTP 代理 CONNECT 两种真实停滞对端，每种重复两轮同 origin：两个请求共享等待，取消第一个不关闭 socket，最后一个取消后 client/pool.close 前三秒内观察 EOF，下一轮成功开始新建连。已有初始 SETTINGS 后单个请求取消、第二请求同连接完成的回归仍通过。临时停用 attempt.cancel 的负向对照，两组 EOF 均三秒超时；finally 恢复源码。完整 Dart 3.5.4 1443 项及严格静态分析通过（负向前正式内容），模块等级不提升，HTTPS 代理外层握手、所有竞态与真实平台云端验证仍未完成。


### 共享取消 HTTPS 代理与 SETTINGS 阶段扩展（2026-10-12）

最后等待者测试新增 HTTPS_TLS（raw 对端接收外层 ClientHello 后停滞）、HTTPS_CONNECT（可信代理 TLS 完成后 CONNECT 停滞）、SETTINGS（目标 TLS 完成后不发送 HTTP2 设置）三种场景；每种两轮同 origin，验证单个取消后最后等待者仍存在，最后取消才观察 EOF，下一轮能够建连。已有 SETTINGS 幸存请求用例扩展显式 connect 使用者：取消唯一管理请求后显式建连仍完成、同 TLS 连接请求成功。

移除 pinned 保护的负向对照捕获底层连接被关闭（peer closed before initial SETTINGS），同时暴露取消异常与释放导致的底层错误竞争；调整 abort 回调先 completeError(RequestAbortedException)，再 release 关闭握手，让取消结果先发布。恢复保护后完整 Dart 3.5.4 1447 项、严格静态分析通过。证据仍不等于全部取消竞争已审计；额外 ALPN 探测、Brotli 与跨平台云端验收仍未完成。


### ALPN HTTP1 回退连接移交（2026-10-12）

抽出 RawTlsSocket 公开 Socket 接口适配器，secureProxyConnection 与 HTTP2 池复用。HTTP2 池在 ALPN 结果为 HTTP1 时保留已协商 TLS socket，不再关闭；nativeHttpClient 的 connectionFactory 优先领取按 origin 保存的 socket。领取前归池所有，pool.close 关闭未移交对象；领取后由原生 HTTP 池管理关闭与空闲复用。非代理客户端保留普通 HttpClient 返回类型及请求头行为。

代理恢复测试新增首次成功 CONNECT 计数必须为 1，矩阵 h1/h2 两次 GET 同样要求 1；HTTP/HTTPS 代理及匿名/Basic 均通过。新增真实 SecureServerSocket 直连，服务端只支持 HTTP1，两次请求成功且只接受一个 TLS socket。负向对照恢复丢弃 ALPN h1 socket，两组代理恢复用例 CONNECT 实际 2、期望 1 失败，finally 恢复源码。最终 Dart 3.5.4 全套 1448 项、严格静态分析通过，包括 h1 大文件/流式取消与重定向。该批关闭额外 ALPN 探测连接差异，但移交期间所有取消/关闭组合、动态协议变化、Brotli、跨平台及云端验收仍需完成。


### ALPN 回退连接移交关闭所有权（2026-10-12）

新增两项真实 SecureServerSocket 测试：未领取的 HTTP1 ALPN socket 在 pool.close 后三秒内令服务端观察 EOF；已通过 takeHttp1Socket 领取的 socket 在 pool.close 后仍可发送 ping/接收 ack，随后由接收方 destroy 触发 EOF。同 origin 第二次领取为 null，池关闭后领取也为 null，均只有一个 TLS 连接。

负向对照临时删除 pool.close 对 _http1Sockets 的 destroy 循环，未领取案例 EOF 三秒超时，finally 恢复源码。Dart 3.5.4 完整回归 1450 项通过，严格静态分析通过；静态分析后仅将多余非空断言改为本地非空变量。该证据证明明确移交前后两种关闭所有权，尚未穷尽领取与请求取消/关闭的竞争，也未完成 Brotli、公开面及跨平台云端验收。


### Brotli 增量候选平台审计（2026-10-12）

审计 es_compression 2.0.15：SDK >=3.2，原生过滤器调用 BrotliDecoderDecompressStream，具备增量接口；但包内 macOS 动态库为 x86_64，当前 arm64 Dart 3.5.4 实际 DynamicLibrary.open 退出 1 并报告架构不兼容。README 要求 Android 应用手动部署 .so；不能未经平台交付处理直接作为 Flutter SDK 默认依赖。独立临时缓存下载，未更改 SDK 依赖，尚未证明该候选的 EOF 前输出或取消释放。详细源版本、archive hash、行为验收要求见 BROTLI.md；最近 SDK 全套仍 1450 项，本轮没有修改生产代码或重跑回归。


### 纯 Dart Brotli 暂停边界审计（2026-10-12）

brotli 0.6.0 进一步审计发现 _doReadMoreInput 填满输入循环、endOfStreamReached 补位与 _decodeToSink 的 16KiB 输出边界，直接异步化输入仍不能证明 flush 前缀输出。新增 tool/audit_brotli_candidate.py，针对固定源码输出 SHA256 和词法输入依赖闭包，实际 59 个核心函数/18 个输入依赖函数；它不是完整静态分析或行为测试。BROTLI.md 记录可恢复状态机需要区分暂缺输入与最终 EOF，避免重跑累积全部输入的伪流式实现。本轮未修改生产代码或依赖，最近全套仍 1450 项，Brotli 缺口保持开放。


### HTTP1 回退统一解压与线上响应头（2026-10-12）

Http2Client 内部回退的 native HttpClient 设置 autoUncompress=false，并将 h2 原有 gzip/x-gzip/deflate 解码抽为公共处理函数，供两条响应路径使用；保持 HEAD/204/304 跳过解码、未知编码整链保持 opaque，Content-Encoding/Content-Length 保留线上值。新增真实本地 HTTP1 服务测试 gzip、x-gzip、zlib deflate、raw DEFLATE 和 gzip, deflate 叠加，逐项验证正文及原始压缩长度头。Dart 3.5.4 全套 1451 项和严格静态分析通过。本批没有覆盖 createHttpClient 的显式直连 h1 _LimitedIOClient；该路径统一解压及 Brotli 仍待处理。


### 显式直连 HTTP1 共用解压（2026-10-12）

将响应解压抽至 http_content_decoder_io.dart，由 Http2Client 与 _LimitedIOClient 共同调用。显式直连 h1 的 HttpClient 同样 autoUncompress=false，以保留线上 Content-Encoding/Content-Length；_DecodedIOStreamedResponse 保留原 IOStreamedResponse 的状态、元数据并委托 detachSocket（本批未专项验证 detach 生命周期）。压缩测试参数化默认回退/显式 h1，两条路径各五种 gzip/x-gzip/zlib deflate/raw 大写 DEFLATE/多层编码均验证正文及线上压缩长度。最终 Dart 3.5.4 全套 1452 项及严格静态分析通过。Brotli 尚未实现，损坏/截断/取消等全流式解码边界与跨平台仍未全部验收。


### deflate 无数据等待时消费者取消（2026-10-12）

新增可控源流验证 gzip、deflate、gzip, deflate 在监听但尚无首段数据时取消必须在一秒内调用源 onCancel。修复前 gzip 通过，deflate 与叠加各一秒超时，源直到测试清理送入数据/EOF 才释放；async* 等待 StreamIterator.moveNext 导致取消无法推进。

替换为 Stream.eventTransformed 与延迟初始化的 ZLibDecoder chunked sink，首个非空字节选择 raw/zlib，取消直接传到输入订阅，不再由异步生成器等待数据。另新增部分 zlib 头 0x78 后取消，确认已初始化解码器也取消上游。首轮实现重复关闭下游导致 Stream is already closed，修复 decoder.close 与 output.close 的互斥路径后，专项 30 项及最终 Dart 3.5.4 全套 1456 项、严格静态分析通过。该证据覆盖转换流上游取消，不代替实际 HTTP socket EOF 及全部压缩错误边界验收。


### 真实 HTTP1 deflate 取消 socket 释放（2026-10-12）

新增 raw ServerSocket 对端，发送 Content-Encoding: deflate 与 chunked 响应头，分别不发送正文或只发送 0x78 压缩头首字节，保持连接不结束。显式 h1 与默认 Http2Client 的明文 HTTP1 回退共四组，在响应流订阅后取消，要求三秒内取消完成且服务端观察 EOF，发生在 client.close 前。转换流单元验证因此补充了真实 TCP 释放证据。最终 Dart 3.5.4 全套 1460 项及严格静态分析通过。测试名中的 HTTP 2 表示客户端版本选项，实际 uri 为 http、协商路径是 h1 回退，不能扩大为真实 HTTP2 取消证据；Brotli 和全错误/平台验收仍开放。


### 真实 HTTP2 压缩响应取消与会话复用（2026-10-12）

新增真实 SecureServerSocket/HTTP2 六组：gzip、deflate、gzip, deflate 各自无正文或服务端发送单个压缩头字节后保持响应不结束。客户端订阅后取消，在两秒内完成并令服务端 onTerminated 触发；随后请求正常返回 next，服务端 stream ID 列表为 [1,3]，验证同一会话没有被误关。部分头案例证明服务端已发送，不单独证明取消时解码器内部消费进度；部分头转换器状态已有前批单元证据。Dart 3.5.4 全套 1466 项、严格静态分析通过，Brotli 和全部解压错误/平台边界仍开放。


### Node 压缩截断及损坏差分语料（2026-10-12）

新增 tool/http_compression_edges_oracle.js，在本地 HTTP 服务通过 Node v22.21.1 原生 fetch 获取 gzip、zlib deflate、raw deflate 的截断长度与中段损坏结果，保存 test/http_compression_edges_vectors.json。共 27 向量，其中 25 个成功解压（包括部分截断）、2 个失败；不能预设截断一律应拒绝。Dart 共用解压器按整块和逐字节输入运行，共 54 次比较，成功正文逐字节一致，失败/成功分类一致。本批未要求 JS/Dart 异常对象类型或消息一致，也不覆盖 wire 长度错误/远端断连等传输故障。新增差分测试通过，Dart 3.5.4 全套 1467 项、严格静态分析通过，生产代码未修改。


### ConnectionConfig 公开成员补齐（2026-10-12）

核对固定源码 connectionConfig.ts 发现公开 static envdPort 与 mergeOpts 未映射。新增可写静态端口字段 49983，以及 Map 泛型浅合并：无 bound 返回 opts 本身，存在 bound 则独立 Map 合并，保留嵌套引用、显式 null 和 __proto__ 普通键。Dart 省略键表达 JS undefined；此入口不接收 JS undefined 值。官方 Sandbox 的 protected envdPort 是独立字段，新增静态值不改变现有沙箱默认路由。

公开 lib/e2b.dart 导入测试验证上述行为，Dart 3.5.4 全套 1468 项、严格静态分析通过。ConnectionConfig 建立 mapped_partial（累计 154/9），不是完整类或行为审计完成。公开面核对另发现 Sandbox 在 Dart 由 E2BClient/绑定资源提供创建管理入口，JS Sandbox 静态与实例同名方法的完整语言映射仍须明确；默认导出记录保持 pending_audit。


### Sandbox 静态创建连接与实例重连（2026-10-12）

Dart 3.5.4 实测确认类静态 connect 与导出实例扩展 connect 可以同名共存。新增 Sandbox.create 与 Sandbox.connect 静态入口，复用 E2BClient 全部已有创建/连接选项；实例 connect 移到 SandboxReconnect 扩展，在标准 lib/e2b.dart 导入下保持原调用形式。工厂默认新建客户端，失败关闭，成功由返回句柄 close 管理；注入 E2BClient 的句柄 close 不关闭调用方客户端。close 为 Dart 生命周期扩展，不删除云端沙箱。

真实 HTTP 测试暴露旧 connect 对 late final commands/git/files/pty 二次赋值抛 LateInitializationError，改为私有可更新字段加公开 getter。测试验证静态创建、实例重连返回自身、管理路由与凭据、内部 close 后拒绝请求、重复 close、静态连接及注入客户端存活；预期路径更正为已有官方 /v2/sandboxes 创建/连接端点。完整 Dart 3.5.4 1469 项、严格静态分析通过。Sandbox 建立 mapped_partial，155 项部分映射/8 项待审计；其余静态管理方法、构造/继承与扩展选择规则、真实平台仍需审计，默认导出保持待审计。


### Sandbox 静态分页入口（2026-10-12）

对照固定 JS sandbox/index.ts 的 static list，新增 Sandbox.list，复用 SandboxPaginator 的惰性请求及逐页客户端释放。支持 limit、nextToken、state、metadata、template、startedAfter、order、RequestOptions，以及 Dart 调用方客户端注入。新增真实 HTTP 测试验证构造时无请求、全部筛选序列化、两页 ID、x-next-token 推进及结束状态。初始测试误将 SandboxState 字符串别名当枚举使用，修正测试后通过；生产类型保持已有字符串别名。

Dart 3.5.4 全套 1470 项、严格静态分析通过。此入口复用现有分页行为，不构成所有分页错误、注入所有权或完整 Sandbox 公开面验收。官方静态 fork 返回 Sandbox 或 Error，后续补齐必须保留该语义，不能仅返回内部结果包装类型；其他静态入口、Brotli 和平台云端验收仍开放。


### Sandbox 静态与实例 Fork 结果语义（2026-10-12）

对照固定 JS Sandbox.fork 与实例 fork，实现静态入口返回 List<Object>，每项为 Sandbox 或 E2BException，保持原始顺序。实例 fork 移至已导出的 SandboxReconnect 扩展并采用相同结果语义；原先实例返回 SandboxForkResult 的调用方需要迁移为类型判断。底层 E2BClient.fork 仍保留包装结果，供内部管理调用和已有客户端接口使用。Dart 不支持直接声明 JS 联合类型，因此以 Object 加文档约束表达。

默认静态工厂成功句柄共享内部客户端，通过一次性释放回调计数，最后句柄 close 才关闭客户端；空成功/全部失败及请求异常立即关闭默认客户端。注入客户端不转移所有权。实例 fork 使用父实例的客户端，不获得独立所有权，父客户端关闭后子句柄亦不可请求，这一 Dart 生命周期约定不同于 JS 模块级连接池。新增真实 HTTP 测试覆盖混合结果/顺序、请求 count/timeout、重复关闭首句柄后其他句柄仍可请求、实例 fork 结果以及最终关闭后请求拒绝。全部失败、异常释放与注入分支仍需专项生命周期验证。

Dart 3.5.4 全套 1471 项、严格静态分析通过；不构成完整 Sandbox 审计，其他静态管理入口、Brotli 与平台云端验收保持开放。


### Sandbox 继承静态管理入口（2026-10-12）

核对固定 sandbox/sandboxApi.ts，补齐 getInfo、kill、pause、betaPause、setTimeout、updateNetwork 六个公开静态方法，复用已有 E2BClient 管理实现。默认临时客户端在 finally 中关闭；注入客户端保持调用方所有权。原同名实例方法迁入导出扩展，保留参数与行为，包括实例 debug setTimeout 跳过请求。扩展名 SandboxReconnect 暂保持兼容，实际覆盖重连及管理操作；直接 dynamic 调用或不导入扩展的选择性导入尚不等同于 JS 实例原型方法。

新增真实 HTTP 测试覆盖六条静态路由、暂停 full/keepMemory 正文、超时正文、注入客户端操作后继续请求，以及六个对应实例操作（getInfo 已有前批验证）。默认错误释放、全部参数组合及扩展 tearoff 尚需专项审计。Dart 3.5.4 全套 1472 项、严格静态分析通过。继承静态 getFullInfo/getMetrics/createSnapshot/listSnapshots/deleteSnapshot 仍待补齐核对，未声明完整公开面完成。


### Sandbox 指标及快照静态入口（2026-10-12）

核对固定 sandboxApi.ts：getFullInfo 为废弃 getInfo 别名，新增 Dart @Deprecated 静态别名；补齐 getMetrics/createSnapshot/listSnapshots/deleteSnapshot。前三种同名实例方法移至已导出扩展保留调用形式。新增公开 SnapshotPaginator，E2BClient.listSnapshots 复用它；默认无客户端分页沿用 ApiClient 惰性工厂，finally 逐页释放，注入客户端保持所有权。当前返回声明中已有 Paginator<SnapshotInfo> 的接口保持兼容。

新增真实 HTTP 测试验证静态/实例指标 start/end 秒值、快照 name/memory 正文、快照 ID、列表构造零请求与过滤/limit、完成状态及删除模板路由。getFullInfo 别名尚无专项调用测试；SnapshotPaginator 独立构造及全部错误/所有权边界仍待专项审计。Dart 3.5.4 全套 1473 项、严格静态分析通过，完整公开面、Brotli 与平台云端验收未完成。


### SnapshotPaginator 公开构造及失败边界（2026-10-12）

复核官方构造：limit 直接保留 undefined，文档 default 100 为服务端默认，不应客户端填充。新增真实 HTTP 独立构造测试，显式空 sandboxId/name 发送空查询值，未传 limit 保持省略；首个 500 不推进 initial 游标，第二次逐次 apiKey 覆盖后成功，缺失 names 返回空列表，结束再次 nextItems 拒绝且没有额外 HTTP。之后通过相同注入客户端调用 getFullInfo 废弃别名及 getInfo，证明分页不关闭调用方客户端及逐次凭据不污染后续请求。

更新 exports.json 的 SnapshotPaginator 从泛型适配映射至具名类，仍为 mapped_partial。Dart 3.5.4 全套 1474 项、严格静态分析及清单 163 导出/113 type-only 校验通过。未新增生产代码，未将新增证据扩大为完整异常、取消、平台或公开面验收。


### Sandbox 主机格式与签名诊断（2026-10-12）

对照官方 Sandbox.getHost/ConnectionConfig.getHost，官方直接字符串插值，没有 1..65535 范围检查。移除 Dart Sandbox 额外 RangeError，将两层端口参数从 int 扩至 num，统一调用已有 jsNumberString 保留 JS 的负零、小数、Infinity/NaN 格式。新增公开 SDK 测试覆盖云端与 debug 主机格式，零、负值、越界、小数及特殊数字。此方法只返回字符串，不保证这些输入可作为有效网络端口使用。

对照 uploadUrl/downloadUrl，对齐非 secured 但显式传 useSignatureExpiration（包括零）时的 InvalidArgumentException 消息。首次测试用 NaN 作 Map 键读取 entries 触发 Dart 空值类型错误，改为记录列表后通过，未据此改动生产逻辑。Dart 3.5.4 完整 1475 项及严格静态分析通过；完整 URL/WHATWG、运行时非法参数与公开类审计仍开放。


### Sandbox 健康端点错误映射（2026-10-12）

官方 isRunning 在 502 直接返回 false，其他非成功响应按 handleEnvdApiError 映射。Dart 原先调用 throwApiError，属于不同错误契约。抽出 envd_api_error.dart，复用文件内容原有映射；健康端点 404 为 NotFoundException，文件路径保持 FileNotFoundException。健康请求补齐 transport.signal/logger/resolveError 传递。

新增 MockClient 响应测试覆盖 200 true、502 false，以及 400/401/404/429/507/500 的异常实际类型、detail、空正文和空 message 的 statusText 回退，共 18 个错误组合。此测试不是传输失败健康重探或真实网络日志验证；这些新传递路径仍需专项证据。Dart 3.5.4 全套 1476 项通过，随后只补测试 if 大括号并通过严格静态分析。非字符串 JSON message 的 JS 强制转换和全部运行时错误仍待审计。


### Sandbox 健康调用故障解析与日志证据（2026-10-12）

新增两个 MockClient 测试：四种初次 http.ClientException 后的探测结果分别为停止、健康、未知、探测失败，每次恰好两次 /health；停止映射 SandboxNotRunningException、探测失败映射 SandboxUnreachableException，二者 cause 保留原始对象，健康/未知保留原始异常身份。逐次 Logger 覆盖只记录到本次 logger，下一次调用回到绑定 logger；预取消 signal 抛相同原因对象且不发请求，后续不带 signal 的请求成功。

本批仅新增验证，无生产代码修改。Dart 3.5.4 全套 1478 项通过；随后只补测试两个 if 大括号，严格静态分析通过。上述证据为模拟传输回调，未证明真实 socket 取消、中途断连、代理错误体或健康重探的五秒超时；完整验收保持开放。


### envd 非字符串 JSON 消息差分（2026-10-12）

tool/envd_message_oracle.js 从固定官方 api.ts 提取 getEnvdApiErrorMessage 的实际函数体，通过 Node v22.21.1 Response.json 消费响应后运行，再以原生 Error(message) 生成消息字符串；不加载整个 SDK，也不宣称执行完整 handleEnvdApiError。保存 13 种 JSON message（null/布尔/零/数字/空串/字符串/数组/对象）向量。共用映射修复 false/0 回退 statusText、数组递归逗号连接、普通对象 [object Object]、JS 数字格式。

Dart 六类状态 400/401/404/429/507/500 共 78 次消息比较通过，完整 Dart 3.5.4 1479 项、严格静态分析通过。502 官方会对消息调用 includes，非法非字符串值可能引发原生 TypeError，而数组包括判断又有不同语义，本批未对齐或声称覆盖该分支。非 JSON 自定义对象/Symbol/undefined 不在当前传输语料范围，完整错误和平台审计保持开放。


### 真实健康响应截断与停止重探（2026-10-12）

新增 sandbox_health_network_test.dart，真实 HttpServer 处理管理连接后，在首个 /health 使用 detachSocket 发送 200/Content-Length:100，仅写 partial 后关闭 socket；随后健康重探返回 JSON 502 sandbox was not found。两次请求都验证 X-Access-Token 存在、X-API-Key 缺席，最终抛 SandboxNotRunningException 且 cause 为原始 http.ClientException，健康请求恰好两次。

参数化 httpVersion 1.1/2，但地址为明文 http，因此后者实际是默认 Http2Client 的 h1 回退，不能宣称真实 HTTP2 覆盖。此证据将前批 MockClient 中途失败路径扩展至实际 TCP/HTTP 正文截断；没有证明全部断连时点、真实 socket 取消或探测超时。Dart 3.5.4 全套 1481 项、严格静态分析通过，生产代码未修改，完整 SDK 等价验收保持开放。


### 真实健康正文停滞取消（2026-10-12）

在 sandbox_health_network_test.dart 新增两组真实 HTTP 测试：发送 200/chunked 响应及一个正文块后不结束，在服务端 flush 完成后取消调用方 signal，三秒内返回相同 StateError 原因对象；三秒内对端观察 EOF 或 SocketException reset，发生在 client.close 前，且健康请求计数仍为一（取消不触发健康重探）。随后不带 signal 的 isRunning 返回 true，计数二。

首轮测试将服务端 TCP reset 作为未处理错误导致失败，修正对端监听同时接受 reset/EOF 为连接终止，不改变生产代码。显式 1.1 与版本选项 2 的明文回退均通过；不覆盖实际 TLS/HTTP2、所有取消竞争或健康探测超时。Dart 3.5.4 全套 1483 项、严格静态分析通过。完整等价验收保持开放。


### 真实 HTTP2 健康正文取消及早期竞争发现（2026-10-12）

新增真实 SecureServerSocket/HTTP2 测试，管理 connect 与两次健康请求共享一个 TLS/h2 会话，流 ID [1,3,5]；响应头日志确认客户端收到头后取消正文，保留同一原因，服务端流 onTerminated 触发且不额外重探，随后 isRunning 成功。管理 API key 与 envd token 各自隔离。清理期连接错误单独接收，运行期仍失败。

首次精确断言 :path 发现 ContentTransport 空 query 生成 /health?；修复仅在非空查询时 replace(queryParameters)，现在 /health 精确断言通过。随后早期取消（仅服务端 sendHeaders/sendData、客户端未确认收到）暴露 http2 2.3.1 协议错误 errorCode1；改为收到头之后的正文阶段测试后通过。这不是早期竞争修复，明确保留下一批优先处理：复现并解决取消后迟到帧导致连接协议错误，不能以正文取消覆盖全部时点。日志 /tmp/e2b-health-h2-debug.log 和 /tmp/e2b-health-h2-stack.log 保留失败证据。

Dart 3.5.4 全套 1484 项通过；之后仅补测试 if 大括号并严格静态分析通过。Brotli、完整公开面及平台云端验收仍开放。


### HTTP2 早期取消根因与独立失败复现（2026-10-12）

新增 tool/h2_early_cancel_repro_test.dart，保留服务端 sendHeaders/sendData 后、客户端响应头确认前取消的时序。显式执行 dart test tool/h2_early_cancel_repro_test.dart --chain-stack-traces 退出 1，连接级协议错误 errorCode1，输出 /tmp/e2b-early-cancel-repro.log。它位于 tool 而非默认 test 搜索目录，明确是待修复缺陷复现，不计入常规通过数，也不应隐藏其失败状态。

审查 http2 2.3.1 lib/src/streams/stream_handler.dart：_terminateStream 将流移除后，_processStreamFrameInternal 的 stream==null/HeadersFrame/client 分支无条件抛 ProtocolException；未区分已关闭本地流与服务端非法新建流。DATA 分支已处理忽略流量窗口，但 HEADERS 必须同时维护 HPACK 解码状态，不能在 SDK 原始输入中直接丢弃帧。下一步需要审计解码位置并选择可交付的底层修补方式（含源许可及依赖封装），再用该复现转绿及完整回归证明。尚未实施修复，最近常规完整回归仍为 1484；不能声明早期取消等价。


### HTTP2 早期取消迟到 HEADERS 修复（2026-10-12）

确认 Connection._handleFrameImpl 在 stream handler 分发前完成 HPACK 解码（原始 connection.dart 337..345）。将 http2 2.3.1 lib 源码保留为 lib/src/vendor/http2 内部实现，含 BSD LICENSE、每文件原始 SHA256 UPSTREAM.json 和补丁说明；避免 path dependency 破坏 SDK 发布，未修改用户 pub 缓存。生产 Http2Client/池改用内部类型，原 http2 依赖移为 dev dependency，真实 TLS 测试对端仍是未修改的 pub http2。池类型专项测试改用内部类型避免不同 Dart library 身份混用。

唯一协议补丁在 stream==null/HeadersFrame/client 分支：已关闭非 idle 流的 HEADERS 已解码 HPACK，直接忽略；idle 流仍进入原 ProtocolException 分支。上游常量名称保留，六个源文件仅豁免 constant_identifier_names 风格规则，其他分析保持启用。将原 tool 独立失败复现移为 test/h2_early_cancel_test.dart，加入同名动态响应头及后续原始 GET 验证解码成功，管理/取消/后续请求流 ID [1,3,5,7]，只建立一个 TLS 会话。临时移除补丁负向退出 1（/tmp/e2b-h2-patch-negative.log），finally 恢复；该证据验证测试能捕获原缺陷。

首轮全套新增原始 GET 未携 envd token，被测试对端身份断言拒绝；修正测试请求携带 token 后完整 Dart 3.5.4 1485 项通过，严格静态分析通过。此批关闭已复现早期取消连接错误，不等同于全部 HTTP2/RFC、非法 idle HEADERS、CONTINUATION 分片和所有 HPACK/取消竞态验证；这些仍需专项审计。此前 tool/h2_early_cancel_repro_test.dart 已移走，其历史失败记录保留在前节，当前常规测试包含修复回归。完整 SDK 目标仍未完成。


### HTTP2 关闭流分片头与 idle 拒绝（2026-10-12）

新增 h2_late_headers_test.dart，以原始 SecureSocket 对端发送 SETTINGS/ACK 和手工帧，不依赖服务端库的正常流状态。首请求 id1 到达后取消，服务端明确观察 RST_STREAM 才发送 id1 HEADERS（END_STREAM，无 END_HEADERS）及 CONTINUATION（END_HEADERS），块内添加 x-late-state:dynamic-value 的 HPACK 增量表项；后续 id3 的 HEADERS 用索引62（0xbe）直接引用该表项。客户端正常得到指定响应头、状态200，只有一个 TLS 会话，流ID [1,3]。这比前批重复响应头测试更直接证明迟到分片头仍更新连接级 HPACK。

另一用例在只打开 id1 时发送 id3 HEADERS，精确断言 TransportConnectionException/errorCode1，证明修补未将 idle 流非法响应当作可忽略关闭流。两项通过，完整 Dart 3.5.4 1487 项、严格静态分析通过；本批无生产代码修改。仍未覆盖所有分片切点、超长头、错误 HPACK、关闭流 DATA 流量窗口以及所有取消时序，完整验收保持开放。


### HTTP2 忽略 DATA 的连接窗口守恒（2026-10-12）

审查内部 http2 2.3.1 processIgnoredDataFrame，发现只 dataProcessed 增加窗口并发 WINDOW_UPDATE，却未 gotData 扣除实际收到的字节。新增 h2_ignored_data_test.dart，接收1字节前窗口65535，修复前实际65536/期望65535失败（/tmp/e2b-ignored-data-negative.log）。修补为先扣除再归还；测试五段累计64001字节后每次窗口仍65535，同时解析真实 FrameWriter 输出验证连接级 WINDOW_UPDATE 总额64001。

原始 TLS/h2 测试扩展 data 场景：收到取消流 RST 后发送迟到分片头及四个16000字节 DATA，服务端解析客户端 WINDOW_UPDATE，等待恰好64000连接额度，再发起下一请求，HPACK 动态头解码及同TLS会话流 [1,3] 通过。防止重复 RST 导致测试重复发送，增加一次性 sentLate 标志。

Dart 3.5.4 完整1489项通过；之后仅补测试if大括号，严格静态分析通过。补丁说明已更新，原始哈希仍记录上游版本。当前处理沿用 bytes.length，padded DATA 的 pad-length/padding 对连接及流窗口影响尚未审计，不声明完整RFC流控验收；完整 SDK 目标保持开放。


### HTTP2 DATA padding 连接及流窗口（2026-10-12）

原始 TLS 用例扩展 padded 场景：四帧各16000正文+255padding+1长度字节，共65024负载。修复前等待完整额度三秒超时（只归还64000正文），证据 /tmp/e2b-h2-padding-negative.log。DataMessage 新增可选 flowControlLength，默认正文长度保持原调用；接收 DataFrame 使用 header.length，连接窗口先扣完整负载，padding立即归还，正文在消费时归还。流队列同样先扣完整 flowControlLength 再立即归还 padding；关闭流忽略 DATA 按整个 header.length 扣除及归还。

真实TLS对端现在观察到65024额度后继续同会话请求成功；正常流随后发送带255padding的正文ok，用户只收到ok。新增流队列单元验证259字节负载含3字节正文，未消费前窗口65532、消费后65535。Dart 3.5.4 全套1491项、严格静态分析通过。未覆盖全部padding长度、空DATA、错误长度和窗口溢出组合，完整协议及SDK验收仍开放。


### HTTP2 空 DATA 零增量修复（2026-10-12）

新增队列测试，忽略零长度 DATA 后窗口仍65535且 FrameWriter 不应输出任何字节；原实现生成 WINDOW_UPDATE delta0，测试退出1（/tmp/e2b-h2-empty-negative.log）。在 processIgnoredDataFrame 为 header.length==0 增加返回，避免非法零增量。

原始TLS/h2对端增加 empty 场景：收到RST后迟到分片头及空DATA，所有收到的WINDOW_UPDATE均断言增量大于0，后续动态头索引解码、流[1,3]和单TLS会话复用仍通过。Dart 3.5.4 完整1493项、严格静态分析通过。此修复限于被忽略的空DATA；未将该证据扩大为全部空帧、错误padding、窗口溢出或完整协议验收。


### 内部 HTTP2 源码交付与 Web 复验（2026-10-12）

离线 pub get 同步 http2 lockfile 分类为 direct dev；补齐内部 BSD AUTHORS，并将来源/修改记录加入 THIRD_PARTY_NOTICES.md。现有 CI dart format --output=none --set-exit-if-changed lib test example 实测退出0，无需排除第三方源码格式检查。Dart3.5.4 编译 example/web.dart、web_routing_smoke.dart、web_volume_smoke.dart 均退出0；两项 Node 非IO分支冒烟输出成功，不等于真实浏览器网络或 Flutter 验收。

首次 publish --dry-run 被测试专用 TLS 私钥扫描阻止；新增 .pubignore 排除 test/tool/docs/.github 等非运行时材料，所有工作文档及测试仍保留在工作区。复验包约160KB，内部源码/README/UPSTREAM/BSD LICENSE/AUTHORS和根第三方说明包含，fixture key不包含。复验退出65，只有缺少 homepage/repository 警告，不能报告发布检查全通过；未虚构项目仓库地址，也没有执行真实发布。最近全套仍1493，本批仅打包/许可/lockfile变更，未重复生产回归。


### ApiClient.api 低层 JSON 入口（2026-10-12）

固定官方 ApiClient 唯一公开字段 api 为 openapi-fetch 客户端。新增 Dart ApiEndpointClient 与 ApiResponse，并通过 ApiClient.api 稳定 getter 暴露 GET/HEAD/POST/PUT/PATCH/DELETE/OPTIONS/TRACE 和通用 request。Dart 命名参数 pathParameters/query/body/RequestOptions 表达 JS 嵌套参数；body 扩至 Object? 以支持 JSON 数组/原始值。requestResponse 增加默认保持原行为的 validateStatus/addJsonContentType，低层不将HTTP状态抛错且仅有正文时自动加JSON内容类型。低层响应区分 data/error/原始 http.Response，传输、取消、JSON解析异常仍抛出。

新增三项 MockClient 测试覆盖七种成功/错误状态与高层继续抛错、URL路径转义和数组逗号查询、JSON数组正文及方法封装、空/HEAD/204结果和非法JSON。完整 Dart3.5.4 1496项通过；之后仅补生产辅助函数if大括号，严格静态分析通过。ApiClient清单建立 mapped_partial，156/7，163导出校验通过。尚不支持 openapi-fetch middleware/use/eject、parseAs、全部 serializer配置、生成schema paths/components，构造方式和逐次选项也有语言适配；空响应/异常JSON和真实网络仍需差分，不能宣称完整底层客户端等价。


### 低层响应解析官方依赖差分（2026-10-12）

官方 package.json ^0.17.0、pnpm-lock 固定 openapi-fetch 0.17.0。读取官方标签源码 https://raw.githubusercontent.com/openapi-ts/openapi-typescript/openapi-fetch@0.17.0/packages/openapi-fetch/src/index.js，并保存临时模块；tool/api_parse_oracle.mjs 直接导入执行真实 createClient，Node Response 注入 fetch，生成48个 status/method/parseAs/body 向量，不是重写参考算法。test/api_parse_vectors.json 保存结果，JSON解析抛错映射 Dart FormatException，其余 data/error逐值比较。

修复前错误响应强制JSON解析，与官方尝试JSON失败回退文本不符；现在错误解析独立于parseAs。HEAD/204/content-length0（非chunked）为空，304按错误分支，空错误正文无长度头返回空字符串。成功parseAs支持json/text/arrayBuffer（Uint8List），JSON无长度头空正文返回null，方法统一大写，文本使用UTF8忽略charset并允许替代非法字节。新增两项测试，Dart3.5.4完整1498项及严格静态分析通过。

stream/blob/formData、middleware、全serializer配置及schema仍未移植；当前网络层会缓冲成功正文，不能把arrayBuffer支持宣称流式响应完成。文本/字节解析保留原始http.Response，Dart没有浏览器Response的一次性bodyUsed语义。此批不构成完整openapi-fetch等价。


## 2026-10-12：低层 API 查询与路径序列化

- 使用锁定的 openapi-fetch 0.17.0 实际 createClient/fetch 生成官方 URL 期望，脚本为 `tool/api_query_oracle.mjs` 与 `tool/api_path_oracle.mjs`，固定向量位于对应 `test/api_*_vectors.json`。
- 查询 13 个向量覆盖空数组省略、逐项编码后逗号连接、deepObject、整数属性键排序、空值及嵌套对象拒绝。
- 路径 66 个向量覆盖 simple/label/matrix 与 explode 两种形式，标量、空数组/对象、null、重复占位符、数组和对象编码、整数属性键顺序、嵌套值拒绝。修复原来的简单替换实现。
- 两类 URL 比较均先通过 Dart Uri 规范化官方输出。Dart 会转义查询键字面方括号，官方 Node Request URL 保留方括号；这一字节差异仍开放，测试通过不代表完整 URL 序列化等价。完整 WHATWG/IDNA 也未验收。
- 验证：Dart 3.5.4 完整回归 1500 项通过（`/tmp/e2b-api-path-full.log`）；Dart 3.11.3 严格静态分析无问题。未进行真实浏览器或 E2B 云端验证。
- 低层 Middleware、stream/Blob/FormData、生成 schema 仍未完成，模块保持 L2。


## 2026-10-12：逐次自定义查询序列化

新增公开 ApiQuerySerializer 回调，request 与八个大写 HTTP 入口均接受 querySerializer。传入原始 query Map，回调覆盖默认序列化，去除一个前导问号，空结果省略 query；异常在发请求前传播。后续未指定回调时恢复默认规则。

`test/api_custom_query_test.dart` 验证上述行为；锁定官方模块实执行验证 GET/HEAD/POST/PUT/PATCH/DELETE/OPTIONS 的同一回调身份和 URL 输出。TRACE 的 Dart 转发测试通过，但官方 Node Request 在网络发送前拒绝 TRACE；这是一项新确认的开放差异，不能把八入口均测试通过解释为八方法等价。自定义 pathSerializer 和 querySerializer 配置对象形式尚未实现。

Dart 3.5.4 全套 1501 项通过（`/tmp/e2b-api-custom-query-full.log`），Dart 3.11.3 严格静态分析通过。模块仍为 L2。


## 2026-10-12：用户调整等价范围

目标调整为「实现官方 JS SDK 的等价移植，以在 Dart/Flutter 环境下可用为准」。此前记录中的 JS 运行时逐字节差异不自动构成发布阻塞；应判断其是否影响服务端协议或实际使用。查询方括号编码差异、Fetch 禁用 TRACE 与 Dart 允许发送的差异目前保留为运行时适配记录，尚未证明其影响 E2B 业务接口。核心功能缺失、协议错误、流式/取消问题以及适用平台和真实服务验收仍需关闭。历史记录保留作证据，当前判断以本节和推进看板最新范围为准。


## 2026-10-12：Flutter 工程集成验证

新增 `example/flutter` 独立 path 依赖工程，包含 Material 组件及通过注入 E2BClient 创建沙箱的流程。默认不含凭据，未注入客户端时按钮禁用。客户端生命周期由宿主管理。README 记录运行方式、资源清理和验收边界。

Flutter 3.41.5 依赖解析成功，flutter analyze 无问题，flutter test 两项通过：POST /v2/sandboxes 的请求/认证及成功 ID 展示、无客户端禁用按钮。初版测试误写 /sandboxes 导致失败，按当前源码修正后通过。CI 新增独立 Flutter 分析/组件测试任务，尚未执行远端 CI。

这些是 Flutter 测试运行时与模拟 HTTP 验证，未包含平台 runner 构建、真实浏览器网络、移动设备、桌面设备或云端联调。当前平台模块保持 L2。


## 2026-10-12：Flutter Web JavaScript/Wasm 发布构建

为 `example/flutter` 添加 `web/index.html` runner。使用 Flutter 3.41.5 在独立示例目录执行 `flutter build web --no-pub`，退出 0，18.7 秒；执行 `flutter build web --wasm --no-pub`，退出 0，16.9 秒。编译产物位于示例 build/web（生成文件，不作为源码交付）。CI 增加标准 Web 构建任务；Wasm 当前仅本地构建验证。

两种编译均包含 SDK path 依赖，但未启动浏览器、未进行 CORS/真实 fetch/取消/流传输验证，也未连接 E2B 云端。Flutter 组件测试前批两项通过，SDK 全套最近为 1501 项；本批仅新增 Web runner 和 CI/文档，无 SDK 运行时代码改动。


## 2026-10-12：真实 Chrome 跨域管理网络

新增 `test/browser_network_test.dart`（仅 browser 平台）及 `tool/browser_network_test.py`。脚本绑定本机 127.0.0.1:18763，启动 CORS peer、运行 Dart Chrome 测试，退出时关闭服务。无需云端凭据。Chrome 使用实际浏览器 HTTP 实现而非注入 MockClient；验证 GET 查询数组、X-API-Key 传递、JSON 成功及 403 错误结果。服务端要求至少一次预检和恰好两次 GET，避免仅凭浏览器端成功认定网络执行。

本地 Dart 3.11.3 + 已安装 Chrome 执行退出 0，一项测试通过，peer 记录 2 OPTIONS/2 GET（`/tmp/e2b-browser-network.log`）。stable Dart CI 加入同一脚本，远端尚未执行。普通 Dart VM 全套跳过此 browser-only 文件。

这是本地真实浏览器跨域管理 HTTP 证据，不代表真实 E2B CORS、文件流、取消、Flutter 页面运行或移动/桌面网络验收。平台等级仍为 L2。


## 2026-10-12：真实 Chrome 请求取消及复用

扩展 browser_network_test：本地 /slow 接收请求后等待套接字关闭；浏览器通过 /stats 确认服务端已进入 slow，再触发 CancellationSignal。测试要求同一 StateError 原因传播、三秒内完成、服务端观察 EOF/reset、同一客户端随后 /echo 成功。状态轮询最多 100 次且每次间隔 20ms，服务端读超时五秒，避免无限等待。

本地真实 Chrome 两项测试通过，脚本退出 0；peer 记录 5 OPTIONS/7 GET（包含状态轮询，次数允许变化）。证据 `/tmp/e2b-browser-cancel.log`。仅证明响应头前取消；响应头后/响应体流中取消与文件传输仍待验证，不扩大为全部浏览器取消等价结论。


## 2026-10-12：真实 Chrome 文件字节与流式交付

扩展现有 CORS peer 的 /files 路径，返回 [0,128,255,1,2,3]。/stream 文件在写入并 flush 首三字节后等待 release-file；浏览器必须在三秒内收到首块，随后才通过控制请求释放尾块，最终校验完整字节。此握手证明首事件发生在 EOF 前，不能用全响应缓冲实现通过该测试。

使用真实 http.Client 浏览器实现与 Filesystem/EnvdTransport，未注入模拟客户端。本地 Chrome 三项测试通过（`/tmp/e2b-browser-files.log`），记录 6 OPTIONS/9 GET；统计包含状态轮询，允许次数变化。仅验证本地文件读取，文件响应体取消、上传、压缩、云端认证/跨域和真实 Flutter 页面仍待验收。


## 2026-10-12：真实 Chrome 文件响应体订阅取消

/files 的 cancel 分支写入首块后等待 socket EOF/reset，五秒超时。浏览器通过 StreamIterator 读到首块后取消订阅，要求三秒内完成；随后轮询服务端 fileClosed 标志，并使用同一 http.Client 完整读取另一文件。脚本成功条件新增服务端确实观察到文件连接关闭，避免仅客户端 Future 完成就认定取消成功。

真实 Chrome 四项测试通过，退出 0，peer 记录 6 OPTIONS/13 GET（包括次数可变的状态轮询），证据 `/tmp/e2b-browser-file-cancel.log`。覆盖的是订阅取消；RequestOptions.signal 在响应体阶段的行为、上传和云端联调仍待验证。


## 2026-10-12：真实 Chrome multipart 文件上传

通过 Filesystem.writeFiles 上传三个文件：原始高位字节、中文 UTF-8 文本、分两块的 Stream 输入。本地 CORS peer 使用 Python email multipart parser 独立校验文件名和字节，返回每文件 EntryInfo；浏览器验证 path/size 映射。脚本成功条件要求服务端 upload_ok，不仅依赖客户端响应。首轮服务端把 /files? 与 /files 作字面比较而失败，按 URI path 匹配修正；字节从首轮即完整正确。

真实 Chrome 五项测试通过，脚本退出 0（`/tmp/e2b-browser-upload.log`）。Web multipart 对 Stream 输入先缓冲，测试不证明网络流式上传、背压或大文件内存边界。云端、gzip 上传和上传取消仍待验证。


## 2026-10-12：真实 Chrome 文件响应体 signal 取消

新增独立 /signal-cancel 文件请求与服务端 fileSignalClosed 标记，避免复用订阅取消的成功状态。浏览器读取首块后，通过 RequestOptions.signal 触发同一个 StateError；下一次读取必须三秒内抛出该对象，服务端观察 EOF/reset，同一 HTTP 客户端后续完整读取另一文件。既有订阅取消测试独立保留。

真实 Chrome 六项测试通过，peer 记录 6 OPTIONS/15 GET（状态轮询次数可变），日志 `/tmp/e2b-browser-file-signal.log`。本轮复验 Dart 3.5.4 完整 1501 项通过（browser-only 测试不计入 VM），严格静态分析通过。上传取消/压缩、云端和其他平台网络仍未验收。


## 2026-10-12：真实 Chrome gzip 文件响应

本地 /files compressed 分支发送真实 gzip 二进制及 Content-Encoding/压缩后 Content-Length。浏览器 Filesystem.readBytes 与 readStream 使用 gzip:true，均还原 [0,128,255,1,2,3]；证明浏览器自动解压与 SDK 当前处理没有重复解压。测试没有断言浏览器允许覆盖 Accept-Encoding（该请求头由浏览器控制）。

真实 Chrome 七项通过，日志 `/tmp/e2b-browser-gzip.log`，本轮 peer 6 OPTIONS/17 GET。该证据仅覆盖浏览器 gzip，不关闭原生 Brotli、压缩上传或大体积压缩流背压验收。


## 2026-10-12：真实 Chrome gzip 上传与元数据

以 envd 0.6.4 开启 gzip/octet-stream 分支。浏览器 Filesystem.write 上传高位字节与 X-Metadata-source；本地服务仅在 Content-Encoding=gzip 时解压，并核对路径、完整六字节及元数据。脚本成功条件要求 gzip_upload_ok。浏览器验证返回 EntryInfo 路径和大小。

真实 Chrome 八项通过，日志 `/tmp/e2b-browser-gzip-upload.log`，peer 本轮 7 OPTIONS/17 GET，另有 multipart/gzip POST。Web 实现先缓冲再压缩；不作为网络流式上传或大文件内存验收证据。上传取消及云端仍待验证。


## 2026-10-12：上传输入缓冲取消修复

此前 Filesystem multipart 与 Web prepareUpload 使用 fold 收集输入，仅在收集前后检查取消；源流不结束时取消无法及时完成。新增 collectUploadBytes，监听 CancellationSignal，保留原始原因，finally 取消输入订阅并移除信号监听。Web gzip/octet 准备、multipart 和 Volume writeFile 的 Web 准备均传入对应传输 signal。原生 prepareUpload 接受 signal 并预检查，原生网络流仍由原有 transport 管理。

真实 Chrome 新增两种准备模式（multipart/gzip）测试：输入流保持未关闭，确认已订阅后添加数据并取消，三秒内原始异常传播、源 onCancel 执行。九项浏览器测试通过（`/tmp/e2b-browser-buffer-cancel.log`），现有网络/上传结果继续正常。Dart 3.5.4 全套 1501 项通过（`/tmp/e2b-buffer-cancel-full.log`），严格静态分析通过。Volume 已接入共享逻辑，但本批未新增 Volume 浏览器专属测试；网络发送中的上传取消仍待验收。


## 2026-10-12：真实 Chrome Volume 上传与缓冲取消

通过 Volume.writeFile 的公开入口，先取消保持打开的输入流，要求三秒内传播原始异常、源订阅释放；随后同一 Volume 使用新选项上传两块输入。真实本地 PUT 服务独立核对路径、完整四字节、Authorization Volume token 和管理 X-API-Key 缺失。脚本成功条件要求 volume_upload_ok。

真实 Chrome 十项测试通过（`/tmp/e2b-browser-volume-network.log`），本轮 8 OPTIONS/17 GET，另有 POST/PUT；状态轮询次数可变。此证据补齐上一批仅共享代码接入而未直接验证的 Volume Web 路径。仍是缓冲上传，不代表网络流式上传、云端持久化/挂载或上传发送阶段取消验收。


## 2026-10-12：可执行云端 smoke 验收入口

新增 tool/cloud_smoke.dart 和 docs/CLOUD_VALIDATION.md。使用环境凭据，创建两分钟超时沙箱；逐步验证健康、信息、二进制文件、文件流、命令回调，并 finally 删除。JSON 报告只包含阶段名和异常类型，不输出密钥/响应头/异常正文。无凭据退出 78/not_run，与通过明确区分；不纳入自动 CI 创建云资源。

当前环境 E2B_API_KEY 未配置，实际运行返回 not_run/78，未创建云端资源。Dart 3.11.3 严格静态分析通过，原生 AOT 编译通过。脚本存在/编译不作为云端联调证据，真实云端仍待执行，也不替代 PTY/监听/Secrets/Volume/Template 验收。


## 2026-10-13：最低 Dart 版本声明修正

下载官方 macOS arm64 Dart 3.4.0，在 /tmp/e2b-min-sdk-check 隔离副本联网解析兼容依赖（test 1.25.8）后运行。原生分析报三处 ConnectionTask.fromSocket 缺失，完整测试加载失败；Web 编译通过。日志 /tmp/e2b-dart34-full.log 与 /tmp/e2b-dart34-analyze.log。SDK 中 ConnectionTask 为 final 类，无法通过外部 implements 补齐该工厂。

不再宣称 3.4 支持：根包和 Flutter 示例约束调整 >=3.5.4，CI 矩阵从 3.4/3.5.4/stable 改为 3.5.4/stable。选择已实测全套 1501 项的 3.5.4，而非未经验证的更早 3.5 补丁版本。历史 3.4 待验收表述以本节为准。此为支持范围的明确下限修正，不改变 E2B 功能范围。


## 2026-10-13：干净检出时的分析边界修复

将源文件复制到 /tmp/e2b-clean-package-check，排除 .dart_tool/build，独立 Dart 3.5.4 pub get 后根 analyze 失败：Flutter 子工程没有自己的依赖解析，material.dart 等不可解析。本机先前生成的 Flutter 配置掩盖此问题。根 analysis_options 明确排除 example/flutter/**；子工程新增独立 recommended lints 配置，仍由已有 Flutter CI job 分析。

修复后无 Flutter package_config 的干净副本 Dart 3.5.4 analyze 无问题；当前工作区根分析与 Flutter 3.41.5 独立分析通过。并非关闭 Flutter 检查，而是明确独立依赖图/运行时各自检查。未执行远端 CI。


## 2026-10-13：模板公开类型名称适配

Dart Template 已实现 mutable DSL。本批新增 TemplateBase/TemplateBuilder/TemplateClass 类型别名，明确共用同一类型、不提供 TypeScript 阶段方法限制；不虚构额外运行时类。公开测试验证别名构造、同实例链式调用和 JSON/Dockerfile 序列化。Template 及三种名称记录部分映射，不能据此认定所有成员或静态配置继承等价。

模板专项 38 项、Dart 3.5.4 全套 1502 项、严格静态分析通过，163 项导出清单校验通过。累计 160 部分映射/3 待审计；剩余为 components/paths schema 和 JS default 入口。完整公开面/平台/真实构建审计仍未完成。


## 2026-10-13：Template 静态公开入口

新增 Template.build/buildInBackground 及 WithOptions 形式、exists/aliasExists、assignTags/removeTags/getTags/getBuildStatus，委托已有 Templates 绑定实现。默认内部 ApiClient finally 关闭；注入客户端归调用方。构建参数转发 tags/资源/skipCache/logs/连接选项，前台支持 pollInterval。Dart 命名参数表达与 JS overload 形式不同。

新增静态入口测试覆盖六次管理调用、逐次 API key、logsOffset、构建空名称拒绝和注入客户端后续可用。测试响应初版缺少必需 ID 字段导致失败，修正夹具后完整 Dart 3.5.4 1503 项通过（/tmp/e2b-template-static-pass.log），严格静态分析通过。成功构建仍主要由已有绑定实现测试支持；本批未证明静态默认客户端真实构建或云端部署。导出保持部分映射。


## 2026-10-13：Template 静态默认客户端成功网络路径

新增 test/template_static_network_test.dart，真实本地 HttpServer 接收默认内部 ApiClient 的创建、构建提交和状态请求。验证逐次 API key/URL/资源参数、Python 基础镜像，ready 含日志后继续尾部轮询并将 logsOffset 从 0 推进到 1；日志仅投递一次，开始/结束回调正确。后台静态构建仅创建和提交，不进行状态轮询。测试没有注入 MockClient。

专项通过，Dart 3.5.4 全套 1504 项通过（/tmp/e2b-template-network-full.log），严格静态分析通过。该证据补齐默认静态成功路径，但未验证云端镜像构建/COPY 上传，也未独立计数所有 socket 生命周期；保持模块 L2。


## 2026-10-13：Volume 静态公开面与客户端生命周期

新增 Volume.create/connect/getInfo/list/destroy。默认 create/connect 将内部 ApiClient 留给返回实例并由幂等 close() 释放；失败立即关闭。纯管理静态调用 finally 关闭默认客户端，注入客户端由调用方管理。close 不删除持久化存储。Dart 不允许同类静态和实例同名，实例 list/getInfo 改为导出 VolumeContent 扩展；普通完整 import 保留调用形式，dynamic/selective-import/subclass 覆写语义存在语言适配差异。

新增真实本地 HttpServer 验证七请求：创建、连接、静态信息/列表/删除、实例目录/路径信息；管理 API key 不进入内容请求，内容使用 Volume token。Dart 3.5.4 全套 1505 项通过（/tmp/e2b-volume-static-full.log），严格静态分析通过。未独立证明全部默认/注入客户端 socket 释放时序，也未进行云端持久化/挂载验收；保持 L2。


## 2026-10-13：Flutter macOS arm64 发布构建

临时 flutter create macOS runner 接入当前 SDK path 依赖与 Flutter 示例入口，配置 Debug/Release network.client entitlement。Flutter 3.41.5 + Xcode 27 首次因默认 deployment target 10.15 被拒绝；改为 12.0 后 universal 架构校验失败（framework 实有 x86_64/arm64，工具校验仍拒绝）。设置宿主 arm64 后发布构建成功，18.9MB app，日志 /tmp/e2b-flutter-macos-arm64.log。不能把它解释为 universal 构建通过。

新增 tool/flutter_macos_check.py 重现隔离 runner/网络权限/最低目标/宿主架构构建；脚本语法检查通过，本批成功构建由等价的逐步命令完成，未再重复运行完整脚本。docs/FLUTTER_PLATFORMS.md 记录平台边界。未启动 app，未验证签名分发、沙盒内真实网络、云端或其他 OS。SDK 测试仍为前批 1505 项。


## 2026-10-13：macOS 发布应用实际沙盒网络

新增 Flutter network_check.dart 入口，使用本地测试 key 与运行环境传入的 loopback 地址；初始化 Flutter 绑定后通过 E2BClient 创建一分钟沙箱，finally 删除并关闭客户端，stdout 仅输出通过/失败。macos_network_peer.py 独立校验 POST /v2/sandboxes、timeout 60、API key 与 DELETE /sandboxes/macos-local 顺序，30 秒超时。无真实云资源。

隔离 arm64 runner 发布构建并执行退出 0，应用报告 passed，peer 确认 create/kill。codesign 检查实际产物包含 app-sandbox=true/network.client=true（同时带开发 get-task-allow，不是分发签名验收）。日志 /tmp/e2b-macos-local-network.log。构建脚本新增 --network-check 重现，脚本语法检查；本批按分步命令完成相同流程。未验证完整 Flutter UI、文件/命令流、云端、universal 或其他 OS。


## 2026-10-13：原生 multipart 定稿顺序修复与 macOS 文件运行

macOS 实际上传暴露 Content-Type 缺失：Http2Client 在 MultipartRequest.finalize 生成 boundary/header 前构建 H2 headers，H1 fallback wrapper 也提前复制 headers。现在先 finalize 一次，再读取 headers；H1 wrapper 返回已定稿 ByteStream，H2 也消费同一流，避免二次 finalize。

新增 multipart_native_test 真实 HTTP 测试，两种 allowH2 配置均校验 multipart mime/boundary、文件名及高位字节。Dart 3.5.4 全套 1506 项通过（/tmp/e2b-multipart-header-full.log），严格静态分析通过。

macOS 发布应用重建运行通过：上传六字节、readBytes/readStream 比较、finally kill；peer 校验 X-Access-Token 且无管理 X-API-Key。/tmp/e2b-macos-files-fixed.log。初版 peer 还存在 query 字面匹配过严，已按 path 查询匹配修正。仅本地 envd 协议验收，不代表云端/所有流背压；命令流仍待验证。


## 2026-10-13：macOS 发布应用 Connect 命令流

扩展本地 peer 的 /process.Process/Start，独立解析请求 envelope，核对 bash 参数、envd token 和无管理 API key；返回 start/stdout/end/Connect-end 四种帧。stdout 后等待应用回调通过控制请求确认，再发送退出帧，证明回调发生在 EOF 前。发布应用要求结果 exitCode 0、stdout 与回调累计相同，并 finally 清理。

arm64 发布构建与运行退出 0，peer 确认创建/文件写读/命令/回调确认/删除顺序，日志 /tmp/e2b-macos-command-runtime.log。Flutter 独立分析无问题、Python 脚本语法通过。本地服务模拟 envd 协议，没有执行真实 shell 或云进程；不作为云端进程/PTY/全部流故障验收。SDK 全套最近仍为 1506 项，运行时代码本批未修改。


## 2026-10-13：近期改动后的发布包复验

运行 dart pub publish --dry-run，包体 166KB；将 example/flutter/lib/network_check.dart 诊断入口排除，复验清单确认不包含该文件。既有工具/测试/构建目录排除保持，内部 HTTP2 LICENSE/AUTHORS/UPSTREAM 仍列入包。仅一项缺少 homepage/repository 提示，退出65；未提供真实仓库地址，未编造元数据，未执行发布。日志 /tmp/e2b-publish-package-final.log。

修正 README 顶部旧 Dart >=3.4 为 >=3.5.4，并明确 Android/iOS/Windows/Linux/云端未验收，避免平台支持声明超出证据。CHANGELOG 补齐静态入口、上传取消、multipart 修复和平台验收工具。本批无运行时代码变化，最近全套仍为1506项。


## 2026-10-13：低层请求体序列化

ApiEndpointClient 各入口接受 ApiBodySerializer，返回 String/List<int>/null（省略），接收合并头快照，异常在发请求前传播。core requestResponse 增加已序列化字节路径，高层默认 JSON 保持。Content-Type 精确等于 application/x-www-form-urlencoded 且 body 为 Map 时使用表单编码，按 JS 数字键排序和对象/数组字符串规则处理。Dart encodeQueryComponent 的星号/波浪编码差异显式修正。

tool/api_body_oracle.mjs 执行锁定 openapi-fetch 实际 createClient，生成三组固定向量；测试对照正文精确一致，并验证自定义字节/文本/空体、异常和后续默认 JSON 隔离。Dart 3.5.4 全套1508项通过（/tmp/e2b-api-body-final-full.log），严格分析通过。仅支持 Map 表单，JS URLSearchParams 其他输入形式、FormData、流式自定义请求体仍待适配；不宣称完整 bodySerializer 等价。


## 2026-10-13：表单字符串与序列输入

_formBody 支持 Map、已编码 String、List 键值对。字符串去除一个前导问号，忽略空段，按首个等号分割，+ 转空格，合法百分号解码后宽容 UTF-8 解码；非法百分号保留再编码，字段开头 BOM 保留。键值序列保留重复键/顺序，每项必须恰好两个值。其他类型明确拒绝，未复制 JS 任意对象/迭代器隐式转换。

官方实际 createClient 向量从3组扩到10组，包括损坏 UTF-8/百分号、BOM、重复键和非法序列长度。针对测试通过，Dart 3.5.4 全套1508项通过（/tmp/e2b-form-input-full.log），严格分析通过。不能据此宣称 FormData/流式请求体完成。

## 2026-10-13：低层自定义路径与地址前缀

ApiPathSerializer 接收完整端点 URL 与原始路径参数 Map，支持逐次 apiUrl 覆盖，异常原样传播且不发出请求。八个低层方法均转发此选项。默认路径序列化也在完整 URL 上执行，修复 baseUrl 含 /base/ 等前缀时被 Uri.resolve 丢弃的问题；高层端点解析保持原有行为。

锁定 openapi-fetch 0.17.0 的 createFinalURL 源码及实际 createClient 执行均确认默认 /base/items/ordinary 与自定义 /base/items/x?kept=1 的结果。test/api_custom_path_test.dart 验证地址覆盖、参数引用、路径查询保留、异常与后续默认调用隔离。Dart 3.5.4 全套1509项通过（/tmp/e2b-path-full-verified.log），严格分析通过（/tmp/e2b-path-analyze-verified.log）。该批次未审计的路径查询组合由下一批次继续验证；不能据此宣称所有低层 URL 行为完全等价。


## 2026-10-13：路径查询组合顺序

低层 rawQuery 非空时，在原始完整 URL 文本后追加问号和查询，再交给 Uri.parse；此前 replace(query:) 会覆盖已有查询，与官方 createFinalURL 不同。路径有 fragment 时，追加部分留在 fragment，与官方 Request.url 对照一致。高层未使用 rawQuery 的路径仍保持原有 queryParameters 行为。

tool/api_path_query_oracle.mjs 在锁定 openapi-fetch 0.17.0 实际 createClient 上验证三个查询/片段组合，test/api_custom_path_test.dart 对照相同结果。Dart 3.5.4 全套1510项通过（/tmp/e2b-path-query-full.log），严格分析通过（/tmp/e2b-path-query-analyze.log）。此证据覆盖 URL 构造，不证明 fragment 会作为 HTTP 请求目标发送。


## 2026-10-13：低层序列化顺序

请求体先于路径、路径先于查询序列化。此前 Dart 查询回调在请求体之前执行，现移到完整路径构造之后；默认 JSON 编码也提前完成。自定义回调抛错原样传播，不执行后续回调或网络请求。取消/凭据检查仍由 Dart 传输入口处理，本批次不证明这些检查与 JS Request 构造的全局顺序一致。

tool/api_serializer_order_oracle.mjs 使用固定 openapi-fetch 0.17.0 实际 createClient，验证成功顺序及 body/path/query 三处异常；test/api_custom_path_test.dart 对照同样顺序并验证异常对象身份。Dart 3.5.4 全套1511项通过（/tmp/e2b-serializer-order-full.log），严格分析通过（/tmp/e2b-serializer-order-analyze.log）。


## 2026-10-13：默认导出和生成类型缺口清点

官方 default 是 Sandbox 别名，Dart 命名导出的 Sandbox 对应此入口，静态和实例本地 HTTP 证据沿用 sandbox_static_test。导出清单为161项部分映射、2项待审计。剩余 paths/components 是生成的类型集合，不能用通用 JSON API 代替完成证明。新增 SCHEMA_API.md 记录适配与缺口，schema_inventory.json 清点固定源码36路径、47操作、83 schemas；inventory_schema.py 校验提交和源码哈希，可重复生成/检查。两个 inventory 检查及独立正则计数、schema 名称唯一性检查通过。本批次无运行时代码改动，未重复运行完整 Dart 回归。


## 2026-10-13：生成 schema JSON 类型视图

生成83个 JS 导出 schemas 对应类型（65类、18别名），固定提交和源哈希，检查引用闭包及64个对象的 TS/YAML 字段/必填标志。模型采用 ApiSchema 前缀，按 wire JSON 保留数值/日期、未知字段和键存在性，getter 延迟类型检查。注册表 discriminator 提供类型视图。嵌套 Map 未深拷贝；枚举/nullable 顶层值和完整联合类型的编译约束未完整表达。此批次属于部分生成类型移植，非完整 components/paths 验收。

重生成检查通过；api_schema_test 四项覆盖嵌套 IAM、null/缺失、注册表、日期、类型错误及真实低层 JSON 编码。Dart 3.5.4 全套1515项通过（/tmp/e2b-schema-full.log），严格分析通过（/tmp/e2b-schema-final-analyze.log）。导出清单162部分映射、1待审计。


## 2026-10-13：生成模型命名构造

65个生成类加入命名构造，required 参数按规范必填键生成；可选非 nullable 传 null 省略，可选 nullable 使用 ApiSchemaOptional 包装以区分缺失和显式 null。必填 nullable 参数可传 null。嵌套模型经 ApiSchemaJson 转换，Map/List 递归复制；新构造与 fromJson 的浅复制行为区分记录。注册表联合增加 aws/gcp/registry 类型化变体构造，尚未限制内部 type 字符串。枚举、范围和格式约束仍未完成。

新增三项回归覆盖嵌套构造、集合修改隔离、0/false、可空键和联合构造。重生成检查通过，Dart 3.5.4 全套1518项通过（/tmp/e2b-schema-construct-full.log），严格分析通过（/tmp/e2b-schema-construct-final-analyze.log）。


## 2026-10-13：ApiPaths 类型化调用

依据固定 JS 导出路径清单生成36路径47操作 callable 入口，命名参数对应 path/query/body 的类型和 required；成功体解码为对应 ApiSchema 或列表，无体为 null，保留 raw HTTP 状态、头和错误数据。复用现有管理传输及低层序列化；不增加高层默认值或校验。错误按状态的联合类型、enum/范围与原始 serializer 回调透传仍不完整，平台及云端也未全验收。

生成47操作与源码路径/方法清单逐项对照及重生成检查通过；api_paths_test 四项验证创建、数组查询、分页头、路径编码、204/403、可选请求体。Dart 3.5.4 全套1522项通过（/tmp/e2b-paths-full.log），严格分析通过（/tmp/e2b-paths-analyze.log）。163顶层导出均有部分映射，无完整等价结论。


## 2026-10-13：路径必填规则核对和回调透传

生成器逐项核对47个操作在官方 TS 与 YAML 中的 path/query 参数名及 required、请求体存在性及 required；目前一致，未来差异将阻止生成。绑定新增三种 serializer 选项透传；协议回归验证类型化 body 对象身份、body→path→query→fetch 顺序及定制 URL/正文。没有新增强制 schema/范围校验。

Dart 3.5.4 全套1523项通过（/tmp/e2b-path-options-full.log），严格分析通过（/tmp/e2b-path-options-analyze.log），带 TS 必填审计的重生成检查通过。尚未完成响应状态联合/错误类型、全部格式和云端验收。


## 2026-10-13：components 其他命名空间

生成10种共享错误响应类型，显式包装 ApiResponse 时核对状态码，content 返回 ApiSchemaError，头保留 HTTP 字符串；429数值秒可解析，日期头保留。另生成8参数别名、2头别名以及空 requestBodies/pathItems 的 Never 别名。此适配不假装 HTTP 头本身是 TypeScript 声明的 number，也未实现每个操作的完整状态联合。

新增测试验证状态错误拒绝、错误JSON、坏正文、Retry-After数值/日期及别名可编译。Dart 3.5.4 全套1524项通过（/tmp/e2b-components-full.log）；随后仅增加两个空 Never 别名，最终严格分析通过（/tmp/e2b-components-final-analyze.log）及生成检查通过。


## 2026-10-13：低层 Middleware 首批

增加 ApiMiddleware/ApiMiddlewareContext 与全局 use/eject、逐次 middleware，八个原始方法及47生成入口均透传。请求正序且可替换/短路，响应和网络错误逆序，错误可替换或恢复为响应。短路跳过所有响应钩子，与锁定 JS 实际执行一致。核心管理传输增加可选 exchange，重试在逻辑交换内部复用修改后头快照；无钩子仍采用原传输。

四项专项验证顺序、替换请求、短路、恢复/替换错误、异常和无钩子HTTP发送。tool/api_middleware_oracle.mjs 实际执行固定 openapi-fetch 0.17.0 三种场景。Dart 3.5.4 全套1528项通过（/tmp/e2b-middleware-full.log），严格分析通过（/tmp/e2b-middleware-final-analyze.log），生成检查通过。

已知未闭环：高层直接管理调用未统一注册钩子；响应已缓冲，未复制 Fetch 流响应阶段；Dart预检查/上下文options与JS不同。此批次不能宣称完整 Middleware 等价。
