# 顶层默认导出与 OpenAPI 类型

基准为 e2b 2.55.0，提交 df6c368152b067512702fc677952c0fc4e13c2f0。

官方 index.ts 的 `export default Sandbox` 与命名 Sandbox 指向同一个类。Dart 库采用命名导出，因此直接使用 `import 'package:e2b/e2b.dart';` 后的 `Sandbox`，或使用库前缀 `e2b.Sandbox`。现有 sandbox_static_test 验证了该公开类默认客户端创建、连接和关闭的本地 HTTP 行为。这是导出形式适配，不增加另一个 default 类。

`paths` 与 `components` 仅作为 TypeScript 类型导出，来源为 api/schema.gen.ts。它们提供按路径/方法索引参数、请求体和响应类型的能力；components 还包含响应、参数及头部类型。当前 Dart 高层 SDK 有各模块模型，低层 ApiEndpointClient 接收字符串路径和通用 JSON，但尚未提供完整的生成类型集合。运行时能够请求端点不能证明类型能力已经移植。

当前源码清单包含 36 条路径、47 个操作及 83 个 schemas 定义，见 schema_inventory.json。其中包括旧版或内部端点，不能直接把数量当成高层 SDK 的功能缺口数量。生成脚本核对固定提交并记录源文件 SHA256；清单不证明模型或协议等价。

重现与核验：

```sh
python3 tool/inventory_schema.py /tmp/e2b-upstream
python3 tool/inventory_schema.py /tmp/e2b-upstream --check
python3 tool/inventory_exports.py /tmp/e2b-upstream --check
```

后续工作：逐项将高层模型与 schemas 关联，补充未覆盖的低层请求/响应模型；为路径、方法、参数和响应建立 Dart 类型入口，并验证 wire JSON 和可编译用例。当前 schemas 和路径入口均已建立部分映射；完整类型等价仍待验收。

## 生成模型首批实现

lib/src/api_schema_generated.dart 由 generate_api_schema.py 生成，公开导出83个 ApiSchema 前缀类型：65个 JSON 视图类和18个基础/字典别名。生成范围以 JS 导出的 schema 清单为准；总规范中的额外 schema 不进入公共库。脚本还核对64个对象在官方生成 TypeScript 中的字段名称和必填标志。

模型通过 fromJson 接收 wire JSON，通过类型化 getter 读取字段，toJson 保留未知字段和缺失/显式 null 的区别。日期保留字符串，数字使用 num；注册表联合类型提供 discriminator 及 asAWSRegistry/asGCPRegistry/asGeneralRegistry。字段类型在读取时校验，构造时不执行完整 schema 验证。fromJson 仅复制顶层 Map，嵌套输入不深拷贝；读取的列表/字典为不可修改视图副本。命名参数构造入口会递归转换模型并复制集合。

```dart
final request = ApiSchemaNewSandboxV2.fromJson({'templateID': 'base'});
final response = await client.api.POST('/v2/sandboxes', body: request);
final sandbox = ApiSchemaSandbox.fromJson(
  Map<String, Object?>.from(response.data as Map),
);
print(sandbox.sandboxID);
```

模型可作为 jsonEncode 或低层请求体直接使用。尚缺完整编译时 enum/联合约束、完整路径参数和状态响应约束。components 因 schemas 已有实现改为部分映射；不宣称完整生成类型等价。

```sh
python3 tool/generate_api_schema.py /tmp/e2b-upstream
dart format lib/src/api_schema_generated.dart
python3 tool/generate_api_schema.py /tmp/e2b-upstream --check --dart /absolute/path/to/dart
```

生成依赖系统 Ruby 标准 YAML/JSON 库。83项重生成检查、四项模型专项、Dart 3.5.4 全套1515项及严格分析通过。

## 类型化构造入口

65个模型类提供命名参数构造函数，required 对应规范必填键；基础、引用、字典和列表保持类型约束。可选非空字段传 null 代表省略；可选且允许 null 的字段使用 ApiSchemaOptional<T?> 区分省略和显式 null。必填且可空字段仍要求传参数，可传 null。

```dart
final request = ApiSchemaNewSandboxV2(
  templateID: 'base',
  timeout: 60,
  iam: ApiSchemaSandboxIam(tokens: {
    'service': ApiSchemaSandboxIamToken(
      audience: 'example', tokenType: 'oidc'),
  }),
  mcp: const ApiSchemaOptional(null),
);
final registry = ApiSchemaFromImageRegistry.gcp(
  ApiSchemaGCPRegistry(type: 'gcp', serviceAccountJson: '{}'),
);
```

命名构造会递归把模型转换为 JSON，并复制 List/Map，保留 false、0和空集合。不会填入规范 default，也不校验最小值、格式或 enum 字符串；联合变体构造尚不限制内部 type 字符串。fromJson 仍保留未知字段，供响应解码或需显式保留键的场景使用。

## 路径与方法绑定

ApiPaths 为 JS 导出的36条路径提供47个 callable 绑定，按 HTTP 方法和路径段命名。路径、查询、请求体均为命名参数，必填项为 required；成功 JSON 解码为 ApiSchema 模型或列表。ApiTypedResponse<T> 提供 data、error 和 raw，raw.response 可读取状态码与分页头。错误保持原始低层结果，不强制转换为成功模型。

```dart
final result = await ApiPaths.postV2Sandboxes(client.api,
  body: ApiSchemaNewSandboxV2(templateID: 'base', timeout: 60),
);
print(result.data?.sandboxID);
final listed = await ApiPaths.getV2Sandboxes(client.api,
  state: ['running'], limit: 10,
);
print(listed.raw.response.headers['x-next-token']);
```

绑定复用 ApiEndpointClient 的认证、序列化、取消和错误行为，通过 RequestOptions 覆盖逐次选项。无 JSON 成功体返回 null。参数只保证 Dart 类型/必填约束，不填入服务器默认值，不校验 enum/数值范围。错误响应仍为 Object?，未提供按状态码的联合类型；绑定支持 querySerializer、pathSerializer 和 bodySerializer，按低层回调顺序执行。绑定没有改变高层模块。

```sh
python3 tool/generate_api_paths.py /tmp/e2b-upstream
dart format lib/src/api_paths_generated.dart
python3 tool/generate_api_paths.py /tmp/e2b-upstream --check --dart /absolute/path/to/dart
```

重生成检查与47个路径/方法对照检查通过，四项协议测试覆盖创建、列表分页头、路径编码、204/403和可选请求体；这些测试不等同于47个端点的云端验收。

## 路径声明审计与序列化选项

生成器对全部47操作核对 YAML 与官方生成 TypeScript 的 path/query 参数名、必填标志、请求体存在性和必填标志；不一致即停止。可选请求体与其内部字段的 required 分开处理，例如省略 timeout 请求体与提供含必填 timeout 的模型是不同情况。此检查还不覆盖所有参数格式和响应结构。

全部绑定透传 querySerializer/pathSerializer/bodySerializer。新增协议回归通过类型化创建入口验证请求体模型身份、三个回调顺序及最终 URL/正文；默认响应仍返回类型化模型。回调异常和取消沿用低层客户端行为。

## 共享 components 响应、参数和头

ApiComponentResponse400/401/403/404/409/429/500/502/503/504 对应官方10个共享错误响应。构造时接收原始 ApiResponse 并核对 HTTP 状态，content 提供 ApiSchemaError，headers 保留实际 HTTP 字符串头。错误不是 JSON 对象时，显式读取 content 抛 FormatException；原始结果仍可使用。429 的 retryAfterSeconds 解析数值秒，日期形式返回 null 并保留原头。

```dart
if (result.raw.response.statusCode == 429) {
  final limited = ApiComponentResponse429(result.raw);
  print(limited.content.message);
  print(limited.retryAfterSeconds);
}
```

8个 ApiComponentParameter 前缀别名对应 buildID/paginationLimit/paginationNextToken/sandboxID/secretID/teamID/templateID/volumeID。响应头别名为 ApiComponentHeaderXNextToken 和 ApiComponentHeaderXTotalRunning；实际 HTTP 头仍为 String，需要调用方解析数值。规范空的 requestBodies/pathItems 命名空间对应 Never 别名。

共享响应视图属于 Dart 适配，未引入每个操作按状态码的编译时联合结果；枚举/联合约束和完整响应结构审计仍待完成。

## 低层 Middleware

ApiEndpointClient.use/eject 接收 ApiMiddleware 列表；每次调用可传 middleware 列表，生成的47个 ApiPaths 入口也支持。全局钩子先于逐次钩子，请求正序、响应及网络错误逆序。onRequest 返回 http.Request 替换请求、http.Response 短路、null继续；短路跳过后续请求钩子及所有响应钩子。onError 返回 Error/Exception 替换错误，返回 Response 恢复后执行响应钩子，null保留错误。钩子自身抛错不会进入网络错误处理。

```dart
client.api.use([ApiMiddleware(onRequest: (context) {
  context.request.headers['x-client-tag'] = 'flutter';
  return null;
})]);
```

上下文包含逻辑请求 id、原始 schemaPath、当前 request、pathParameters/query、RequestOptions 和 parseAs；响应/错误阶段另提供 response/error。id 在单进程内递增，不复制 JS 随机格式。请求钩子在逻辑请求重试前执行一次，重试复用修改后请求的头快照。

当前边界：仅低层 API/生成路径已接入，高层直接管理调用尚未统一经过注册钩子；响应钩子接收已缓冲的 http.Response，未覆盖 JS 流式 Response 生命周期。Dart 凭据/取消预检查先于钩子；RequestOptions 不等同于 JS 冻结的完整 options 对象。无钩子时保持原管理传输路径。Middleware 仍属于部分移植。
