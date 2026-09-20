# T03-01 `/v1` 线上契约层 — 运行汇总

- 运行 ID：`t03-01-03`
- 任务：[T03-01 同网二维码配对与信任](../../../../tasks/T03-01.md)
- 日期：2026-09-20
- 分支：`feat/t03-01-wire-contract`
- 基线：`master` @ `0c663d2`
- 主机：Windows 10 22H2，Flutter 3.47.5 / Dart 3.13.4

## 1. 本次实现的内容

| 文件 | 内容 |
| --- | --- |
| `lib/core/protocol/json_body.dart` | 控制体严格解码：大小、BOM、UTF-8、**重复键**、深度、转义（新增） |
| `lib/core/protocol/wire_error.dart` | 错误体 `{code,message,retryable,requestId?}`、`Authorization: Bearer`、`Retry-After`（新增） |
| `lib/core/protocol/protocol_limits.dart` | JSON 深度上限、错误消息长度上限 |
| `lib/core/security/pairing_token.dart` | 限流器新增 `retryAfterSeconds`，为 429 提供 `Retry-After` |
| `test/core/protocol/json_body_test.dart` | 40 项测试 |
| `test/core/protocol/wire_error_test.dart` | 37 项测试 |
| `test/core/security/pairing_token_test.dart` | 新增 2 项（`Retry-After` 来源） |

测试规模：Flutter **486 → 565**；协议层测试 124 → 204。

## 2. 为什么控制体不能只交给 `jsonDecode`

§4 要求：UTF-8、≤1 MiB、**深度 ≤16**、**拒绝重复对象键**、拒绝 NaN/Infinity、不接受 BOM。

Dart 的解码器是合格的 JSON 解析器，会拒绝语法错误——但**它不拒绝重复的对象键**：
它保留最后一个，什么也不说。这正是解析器差分（parser differential）的形状：
两个实现读同一批字节、得出不同的值，于是「按一种读法授权、按另一种读法行事」可以被利用。
§4 用「拒绝」关掉它。

深度同理：`jsonDecode` 会按输入递归，16 层上限必须在**扫描时**执行，而不是解析之后。

所以实现先扫描一次结构（深度、重复键、转义），再交给 `jsonDecode` 取值。
扫描器**刻意不构建值**——两个都构建的解析器就是两次产生分歧的机会，
而这个只需要和自己对「结构在哪里结束」保持一致。

### 重复键可以藏在哪里

`{"a":1,"\u0061":2}` 是同一个键的**两种不同拼写**。若比较原始文本，会判为合法，
然后让解码器静默选一个。所以扫描器**先解码转义再比较**，包括代理对——
这是让这条检查真正等同于 §4 所写内容的唯一办法。三条测试固定它：
普通重复、转义拼写重复、代理对与字面量重复。

**重复键的报错不回显键名**：键来自请求体，而控制体可以携带令牌。
`_fail` 只报「问题 + 字符偏移」，不报内容。有一条测试专门放入一个长「secret」作为键，
断言错误文本里没有它。

## 3. 错误体的 `message` 不是自由文本

§7 要求「message 不含密钥或完整本地路径」。这条规则依赖每个未来的调用者记住它，
而失败在被发现之前是**隐形**的——直到某个令牌出现在日志里。

所以 `WireError.of(code)` **不接受 message 参数**：它写入该错误码的稳定
`messageKey`（来自一个封闭的常量集合）。调用方传什么都到不了这个字段，
因此调用方传什么都不会从它泄漏。有一条测试遍历**全部**错误码，
断言消息匹配 `^[A-Za-z0-9.]+$` 且不含 `/`、`\` 或 PEM 头。

（T02-02 当初把 `messageKey` 注释成「A key rather than a string: §7 requires the message
to carry no secret」，本次是把那句话变成结构。）

**收到的** message 不同：对端可以发任意文本。它只被**限长**并检查控制字符，
**不**尝试猜测它是否含密钥——那种启发式只会带来虚假的安心。这一点写在文档里。

## 4. `retryable` 是校验的，不是采信的

错误体携带 `retryable`，尽管 §11 的表已经按错误码定死了它。
一个发来 `retryable: true` + `CHUNK_HASH_MISMATCH` 的对端，
等于在邀请客户端**永远重试一个损坏的块**。所以解析出的值**必须**与该码在 §11 中的行为一致，
不一致按协议违规拒绝。两个方向都有测试（谎称可重试、以及谎称不可重试）。

## 5. §11 的表被测试钉住

新增两组测试，把 §11 的表作为**数据**写在测试里：

- 表中每个码在枚举里的 `httpStatus` 必须一致；
- 枚举里**没有**表中未出现的码（双向）——「一个码自己发明的状态，就是对端不会预期的状态」；
- 只有 `RATE_LIMITED`、`STORAGE_SYNC_FAILED`、`DB_COMMIT_FAILED` 标记为可重试。

## 6. `Authorization` 与 `Retry-After`

**Bearer 解析**：缺失、别的 scheme、空令牌、多余空白、长度不符、带填充、非 base64url 全部拒绝；
scheme 按 HTTP 规则大小写不敏感。**没有任何从查询串读取令牌的解析器**，所以没有代码路径能那么做。

**`Retry-After`**：只接受 delta-seconds，**拒绝 HTTP-date 形式**——
离线设备的时钟正是协议在别处拒绝信任的东西，客户端误读日期会去猛敲对端、或等得离谱地久。
§11 把退避规定为 429 的行为，所以**429 必须带一个正数延迟**，否则客户端「没有可遵守的东西」。

**限流器现在会给出该等多久**，而且是从**最早的失败**何时移出窗口推导，而不是窗口长度：
在 20 秒就够的时候让客户端等满一分钟，是另一种错。两条测试固定它，
其中一条断言「按返回的秒数等待之后，限流确实解除」——否则这个头就是在撒谎。

## 7. 实际执行的检查

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 格式化 | `dart format lib test tooling` | 通过 |
| 静态分析 | `flutter analyze` | `No issues found!` |
| 全量测试 | `flutter test` | **565 passed** |
| 协议层测试 | `flutter test test/core/protocol` | **204 passed** |
| 链接检查 | `python tooling/checks/check_links.py --strict` | 无断链 |
| 机密检查 | `python tooling/checks/check_secrets.py` | 无凭证材料 |
| CI 工作流检查 | `python tooling/checks/check_ci_workflow.py` | 不变量成立 |

## 8. 未执行与限制

1. **§7 的 16 个端点一个都没实现。** 本次只做了共享契约层（请求体解码、错误体、认证头、退避头）。
   `POST /pair`、`GET /offers`、`POST /transfers`、清单分页、块 PUT/GET、`/checkpoint`、
   `/pause`、`/complete`、`/cancel`、`/control` 等**全部未实现**，请求/响应字段也未建模。
2. **没有 HTTP 服务器或客户端**：没有路由、没有 `Cache-Control: no-store` 的实际写出
   （§7 要求所有控制响应带它）、没有 `Content-Type: application/json; charset=utf-8` 的写出。
3. **错误体尚未接入任何响应路径**：`WireError` 会生成与解析，但没有任何地方发出它。
4. **块体的头与长度规则未实现**（§8：`Content-Type: application/octet-stream`、
   单一 `Content-Length`、不支持 `Transfer-Encoding`、不许压缩、末尾多余数据拒绝并关闭连接）。
5. 未在 Android/iOS 真机运行。

## 9. 需要人工重点复核的区域

- **扫描器与 `jsonDecode` 的一致性**：扫描器只判结构、不取值，两者对同一字符串的分歧
  只可能表现为「扫描通过但解码失败」（会抛错，安全）或「扫描更严」（安全）。
  **但仍需人工确认**：若将来有人给扫描器加上取值逻辑，这个论证就不再成立。
- **错误体里的 `message` 是可显示的文本**。本端写出的永远是 messageKey，
  但**收到**的 message 可以是任意文本，UI 渲染它时必须按不可信输入处理
  （例如不要把它当 Markdown）。目前没有任何 UI 消费它。
- **`Retry-After` 的上限未设**：一个对端可以要求等 999999999 秒。
  §11 没有设上限，本层只做格式校验。**需人工决定**是否加一个客户端侧上限。
- **`requestId` 出现在错误体里**：§7 的 body 允许它。当前只校验它是规范 UUID；
  它是否会与日志中的请求关联需在实现请求管线时确认（**不得**记录完整的
  `Authorization` 头或令牌本身）。
- **§8 的块头规则尚未实现**，因此「`Content-Length` 与 `Transfer-Encoding` 同时出现必须拒绝」
  这类要求目前**没有任何代码覆盖**。
