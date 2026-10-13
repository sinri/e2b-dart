# 流式 Brotli 实现审计

状态：未实现；本页记录方案选择证据，不代表该功能完成。

## 必须满足的行为

- 响应未结束时输出已经能够解压的数据，满足命令日志等持续响应的消费需求。
- 支持 HTTP/2 与原生 HTTP/1.1 回退；Web 使用浏览器原生 fetch 的解压行为。
- 支持 `br` 大小写、多层 Content-Encoding 逆序解码、HEAD/204/304 的无正文边界。
- 截断、损坏数据在正文流上报告错误；取消向上游传播并释放解码器。
- 按消费速度读取，避免缓存完整压缩输入或完整解压输出。
- 保持 Dart >=3.4 与 Flutter 目标范围，不能因新增解压要求用户手工安装系统库。

已有 Node 参考：`tool/http_compression_oracle.js`，包含 Brotli flush 后 EOF 前的前缀验证。接入候选实现前须对同一协议场景逐项运行 Dart 对照。

## 候选审计（2026-10-12）

| 候选 | 证据 | 结论 |
| --- | --- | --- |
| brotli 0.6.0 | 上批已审计：SDK 上限 <3.0；公开转换 sink 缓存全部输入；InputStream 持有完整 List | 不能直接加入当前 Dart 3 SDK。若移植代码，需要重做可恢复输入与解码状态，不能仅修改 SDK 约束 |
| es_compression 2.0.15 | SDK >=3.2；BrotliDecompressFilter 调用 BrotliDecoderDecompressStream；默认输入/输出缓冲 64KiB | 有增量接口，仍需验证 EOF 前输出、暂停、取消及异常时 native 状态释放 |
| es_compression 2.0.15 平台交付 | 包内 esbrotli-mac64.dylib 是 x86_64；当前 Dart 3.5.4 与主机均 arm64；实际 DynamicLibrary.open 失败并报告 incompatible architecture | 不能直接作为全平台默认依赖，需完整原生库构建/打包或选择纯 Dart 可恢复状态机 |
| es_compression Android | README 要求应用复制 .so 至 jniLibs 并设置 ABI | 当前交付方式会增加应用手工配置；不能以桌面运行结果宣称 Flutter 全平台支持 |

来源：[es_compression 仓库](https://github.com/instantiations/es_compression)、[2.0.15 包](https://pub.dev/packages/es_compression/versions/2.0.15)、[Google Brotli 增量解码接口](https://github.com/google/brotli/blob/master/c/include/brotli/decode.h)。

本地审计下载的 es_compression 2.0.15 archive SHA-256：`c1ff7af54802631cf5c3942cb67bb99daadcc087f573ca99a9de91002d1a7ece`。

运行证据：`/tmp/e2b-brotli-runtime-probe/probe.dart` 使用 Dart 3.5.4 调用 DynamicLibrary.open；退出码 1，明确指出 have x86_64 / need arm64。候选下载到独立 PUB_CACHE，未修改 SDK pubspec 或锁文件。

## 下一步

1. 选择能交付全部原生平台的增量实现：审计纯 Dart 状态机移植成本，或落实自动构建与打包的 FFI 方案。
2. 在独立候选工程运行 EOF 前输出、逐字节分块、损坏/截断、取消与慢消费对照，先证明行为再加入 SDK。
3. 接入公共响应解压链，覆盖 h2、h1、代理、多层编码，并运行最低 SDK 与实际 Flutter 平台验证。

本轮只完成候选可用性审计，Brotli 差异保持开放；SDK 最近完整回归仍为 1450 项。

## 纯 Dart 状态改造范围（2026-10-12）

对 brotli 0.6.0 的 decode.dart 进一步审计：

- `_doReadMoreInput` 循环填满内部输入缓冲；短读取并不直接恢复解码，而是继续读取。将 `_readInput` 换成 Future 后仍可能等待后续输入，不能自动满足 flush 前缀输出。
- 输入不足当前设置 `endOfStreamReached` 并补齐读取单元；增量实现必须区分“暂时没有输入”和“真正 EOF”，否则补位可能参与解码。
- `_decodeToSink` 使用 16384 字节输出缓冲，`_decompress` 持续运行至输出边界或结束；小响应前缀需要显式输出/暂停机制，不能依靠输入异步化。
- Huffman 表、bit window、环形字典及命令复制都有跨暂停点状态；禁止以每个 chunk 重跑完整输入来伪装流式处理。

可复现清单工具：`python3 tool/audit_brotli_candidate.py /path/to/brotli-0.6.0`。这是词法调用清单，排除方法/动态调用，不能视作完整静态调用图或等价性证明。

本次扫描核心函数 59 个，输入依赖闭包 18 个：

`_copyBytes`, `_copyUncompressedData`, `_decodeContextMap`, `_decodeHuffmanTreeGroup`, `_decompress`, `_doReadMoreInput`, `_initBitReader`, `_initState`, `_prepare`, `_readComplexHuffmanCode`, `_readHuffmanCode`, `_readHuffmanCodeLengths`, `_readInput`, `_readMetablockHuffmanCodesAndContextMaps`, `_readMetablockPartition`, `_readMoreInput`, `_readNextMetablockHeader`, `_reload`.

源文件 SHA-256：`a1b1f5497aa497567a024b4696435ab63c65dbecc847dcf0dbe3178ecef9283f`。

实现顺序调整为：先定义 needs-input / output-ready / finished 三种状态及真实 EOF 规则，再处理可恢复 bit reader 与命令状态，最后接入响应链。仍未接入 Brotli，也未改变生产依赖。
