# T03-01 §7 请求管线：鉴权决定与控制响应包 — 运行汇总

- 运行 ID：`t03-01-10`
- 任务：[T03-01 同网二维码配对与信任](../../../../tasks/T03-01.md)
- 日期：2026-09-20
- 分支：`feat/t03-01-control-pipeline`
- 基线：`master` @ `f1e2887`
- 主机：Windows 10 22H2，Flutter 3.47.5 / Dart 3.13.4

## 1. 本次实现的内容

| 文件 | 内容 |
| --- | --- |
| `lib/core/protocol/transfer_direction.dart` | `TransferDirection`（§7 的两个方向值，新增） |
| `lib/core/network/control_message.dart` | `ControlRequest`、`ControlResponse`（新增；`lib/core/network/` 目录由此建立） |
| `lib/core/network/control_authorization.dart` | `ControlCredential`、§7 的逐路由要求表、`ControlGrant` 族、`ControlAuthenticator` 端口、`ControlAuthorizer`（新增） |
| `lib/core/network/control_pipeline.dart` | `ControlPipeline`（`APP_AND_SERVICE_DESIGN.md` §5 的请求管线，新增） |
| `test/core/protocol/transfer_direction_test.dart` | 10 项测试 |
| `test/core/network/control_message_test.dart` | 30 项测试 |
| `test/core/network/control_authorization_test.dart` | 24 项测试 |
| `test/core/network/control_pipeline_test.dart` | 21 项测试 |

测试规模：Flutter **803 → 888**。

## 2. 本次补上的是两条一直没人实现的 §7 规则

§7 对**每个控制响应**说了两句话，两句话此前都没有实现：

> 成功体中的 token 字段只出现在专门授权/恢复响应，**所有控制响应 Cache-Control: no-store**。

> 错误体 {code,message,retryable,requestId?}，message 不含密钥或完整本地路径。

第二句此前只做了一半：`WireError` **会**生成与解析错误体，但**没有任何地方发出它**——
「写响应」这一层不存在，所以那张错误码表从未真正上线。
第一句则完全没有代码。

§7 开头还有第三句：

> 所有 ID 参数须先解析校验。**除 pair 外均需要有效 Bearer**，resume 使用 taskResumeSecret
> 专用请求体；初次 resume 无须旧会话令牌。**任务查询对无权限资源统一 404**。

「没有鉴权决定」是台账里登记的剩余项，本次把它实现为**逐路由的要求表**而不是散落的 if。

## 3. `Cache-Control: no-store` 做成结构性而不是约定性

理由与 `WireError.of` 不接受 message 相同：**一条要求每个调用点都记得的规则，会在最要紧的那一次被忘掉**——
即携带令牌的那个响应。

因此 `ControlResponse` **没有**「不带 no-store」的构造方式，也没有 `raw`：

- 每个工厂都加上 `cache-control: no-store`，且放在展开调用方头之后**最后**写入，
  所以调用方自带 `Cache-Control: max-age=3600` 会**输给** §7（测试直接断言这一点）；
- 头映射 `unmodifiable`，事后删不掉；
- 测试还断言「调用方的那次尝试没有留下第二个不同的条目」。

## 4. 内容类型与 1 MiB 也做成结构性

§4 把控制体定为 `application/json; charset=utf-8`、单请求/响应上限 1 MiB。
写出一个**自己 parser 必须拒绝**的响应，比在这里失败更糟（那时原因还看得见），
所以写入时即校验 1 MiB 并抛 `RESOURCE_LIMIT`。
§8 的块体另走 `binary()`：`application/octet-stream` 加 `Content-Length`，不受 1 MiB 控制体限制。

## 5. 鉴权：三条规则必须分开

§7 开头那一句里其实是三件事，**把它们混在一起是通常的错误**：

| | 规则 | 本次实现 |
| --- | --- | --- |
| 1 | **哪条路由要什么凭证** | 逐路由要求表，键为 `ApiRoute.name` |
| 2 | **凭证的作用域** | 会话身份 vs 绑定单个任务的令牌 vs 受限完成查询令牌 |
| 3 | **不够格时答什么** | 缺失/畸形/未知/失效 → **401**；凭证有效但**不覆盖该资源** → **404** |

**第 3 条的两个分支必须分开**，这是本次最要紧的一处：

- §7：「任务查询对无权限资源**统一 404**」。一个属于别的 transfer 的令牌，
  答 `404` 与「这个 transfer 不存在」**不可区分**，否则状态码就成了枚举 transfer id 的工具。
- 而方向违规答 **403** `DIRECTION_FORBIDDEN`：资源存在、调用者也有权看见它，
  但这个操作不属于这个方向。两者混淆会让「不存在的资源」和「用错方向的资源」看起来一样。

## 6. 要求表按路由名索引，缺失即响亮失败

`ControlAuthTable.assertCoversEveryRoute()` 在每次构造管线时运行，断言表与
`ApiRoutes.all` **完全一致**（不多不少）。一条新加进路由表却没有要求的路由会**抛错**，
而不是**默认匿名**。这个失败方向是刻意的：把默认值设成「无需凭证」会把一个新端点变成开放端点。

## 7. `resume` 是第二条例外，而且必须登记

§7 说「除 pair 外均需要有效 Bearer」，紧接着又说 resume 用专用请求体、初次 resume 无须旧会话令牌。
两句直接相邻，**resume 的凭证是 body 里的 secret**，所以管线**不向它索要 Bearer**——
否则**第一次恢复永远无法发生**。本次把它建模为单独的取值 `resumeBodySecret`（而不是 `none`），
以免后来者把它误当成匿名路由；管线**不校验**该 secret，因为 §9 把验证交给**原服务端**，
而那个验证器（及其签发方 `GET /authorization`）尚未实现。已登记。

## 8. 方向校验是 `AGENTS.md` 强制要求，不是额外项

`AGENTS.md` §5：「所有文件请求先验证任务授权、**操作方向**、文件 ID、块编号、长度、偏移范围、
`lease_epoch` 和摘要」。而 §7 逐行点名了方向：块 `PUT` 属 `client_to_server`、
块 `GET` 属 `server_to_client`、checkpoint 由 client 接收者汇报、acceptance 决定由 client 接收者做出。

**方向值做成枚举而不是裸字符串**：一个 `String` 无法被穷尽检查，比较里的拼写错误会照常编译并按不相等处理。
枚举只在协议层定义一次，`TransferDirection.values` 恰好是 §7 的两个值（有测试钉住）。

## 9. 管线：三个阶段有，两个阶段明确没有

`APP_AND_SERVICE_DESIGN.md` §5 定下顺序，本次**逐项说明哪些做了、哪些没做**，而不是含糊带过：

| 阶段 | 本次 |
| --- | --- |
| TLS、pin | **否**——它终止连接，属传输层；管线收到的是已经成帧的 `ControlRequest` |
| 协议版本 | **否**——§3 的协商属配对握手，§7 的其余行不带版本字段。**不发明** |
| token/任务授权 | **是** |
| `request_id` 幂等 | **否**——需要「哪些路由带 requestId」的表与持久记录；两者都已单独存在但未接线 |
| 参数/范围验证 | **是**——由既有的 `ApiRoutes.match` 完成，它在返回前校验每个参数 |
| 用例 | **按名字**：该路由注册的处理函数 |
| 结构化错误 | **是**——`WireError` 终于有了发出点 |

**校验先于鉴权**：§7 要求参数先解析校验，而路由必须先知道才能查到它的凭证要求。
所以一个畸形 target 即使同时也没有令牌，也答 `INVALID_PATH`/`INVALID_FIELD`。
这不泄漏任何东西：路径的形状是公开的，§7 的「统一 404」保护的是**资源**而不是**语法**。

**未注册的路由答 404**：目前**没有任何端点的用例被实现**，所以处理函数表是空的，
每个请求都得到 `NOT_FOUND`。这与 `ApiRoutes` 已经登记的读法一致（§11 没有 405，
且该答案拒绝确认哪些端点存在）。一个半成品服务答 `500` 会比这告诉对端更多。

## 10. 用变异验证关键性质真的被断言

| 变异 | 结果 |
| --- | --- |
| 把 `cache-control: no-store` 放到展开调用方头**之前**（让调用方能覆盖） | **1 项失败**（「调用方无法覆盖」） |
| 把「令牌不覆盖该 transfer」从 `notFound` 改成 `directionForbidden` | **2 项失败**（两处「答 NOT_FOUND 而非 403」） |

两处均随后从备份**恢复原文**，并重新确认 75 项网络测试全部通过。

## 11. 实际执行的检查

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 格式化 | `dart format --output=none --set-exit-if-changed lib test tooling` | 通过（0 changed） |
| 静态分析 | `flutter analyze` | `No issues found!` |
| 全量测试 | `flutter test` | **888 passed**（803→888） |
| 网络层测试 | `flutter test test/core/network` | 75 passed |
| 变异验证 | 2 处临时变异（见 §10） | 1 / 2 项失败，已恢复 |
| 链接检查 | `python tooling/checks/check_links.py --strict` | 无断链 |
| 机密检查 | `python tooling/checks/check_secrets.py` | 无凭证材料 |
| CI 工作流检查 | `python tooling/checks/check_ci_workflow.py` | 不变量成立 |

## 12. 未执行与限制

1. **没有 HTTP 服务器或客户端，没有 TLS**：管线接收的是已经成帧的请求；
   socket、HTTP/1.1 帧解析、TLS 引擎、`pin` 比对都还没有接线。
   本次让 **§8 的块头规则与 §7 的响应规则可以组合**，但把它们接到连接上仍是 HTTP 层的事。
2. **19 个端点的用例一条都没实现**：处理函数表是空的，所有请求答 404。
   `WireError` 现在有发出点，但发出它的都是管线自身的阶段。
3. **协议版本协商未实现**（见 §9）。
4. **`request_id` 幂等未接线**（见 §9）。
5. **会话到任务的映射未建模**：因此一个会话身份在**任务作用域路由**上被**保守拒绝**（答 404），
   而不是接受一个它可能并不拥有的 transfer。这是一个**已知的能力缺口**，不是安全缺口——
   方向是「拒绝得太多」。已登记。
6. **存储层仍以裸 `String` 接收 direction**（`registerTask(direction: 'client_to_server')`），
   而协议层已有 `TransferDirection`。这是**同一概念的两处拼写**，本批未统一：
   转换会改动约 12 个测试文件的调用方式，属机械但面广的改动。
   当前的失配后果是**失败关闭**（方向不符 → 403），不是失败开放。
7. **未在 Android/iOS 真机运行**；本批为纯 Dart 协议/网络层，不含平台代码。
8. **`Retry-After` 的上限仍未定**（沿用 `t03-01-03` 的登记）：本次只保证 429 必须带正数延迟。

## 13. 需要人工重点复核的区域

- **`Cache-Control: no-store` 的结构性保证**：这是本批最可能被后续改动悄悄破坏的地方——
  例如有人为了「某个响应需要缓存」而加一个 `raw` 构造器。复核时应确认没有这样的出口。
- **401 与 404 的分界**（见 §5）：这是本次最重要的安全语义，也是最容易被「顺手统一」成一种答案的地方。
- **`resume` 不索要 Bearer**（见 §7）：这是对 §7 两句话相邻冲突的读法，需在协议冻结前确认。
- **会话身份在任务作用域路由上被拒**（见 §12.5）：能力缺口，需决定是否补会话到任务的映射。
- **`TransferDirection` 与存储层裸字符串并存**（见 §12.6）。
- **处理函数表为空**：任何「服务已可用」的说法都不成立；目前的正确描述是
  「管线可用，端点未实现」。
