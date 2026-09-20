# T03-01 第十一批：`POST /transfers`（第一个可用端点）与三处真实缺陷 — 运行汇总

- 运行 ID：`t03-01-11`
- 任务：[T03-01 同网二维码配对与信任](../../../../tasks/T03-01.md)
- 日期：2026-09-20
- 分支：`feat/t03-01-create-transfer`
- 基线：`master` @ `93b737d`
- 主机：Windows 10 22H2，Flutter 3.47.5 / Dart 3.13.4

## 1. 本次实现的内容

| 文件 | 内容 |
| --- | --- |
| `lib/core/protocol/transfer_creation_request.dart` | `POST /transfers` 请求体（新增） |
| `lib/core/security/credential_fingerprint.dart` | 凭证指纹，供 §9 的幂等作用域使用（新增） |
| `lib/core/network/transfer_creation_handler.dart` | `POST /transfers` 用例（新增） |
| `lib/core/storage/transfer_repository.dart` | `TransferDeclaration` 与 `readDeclaration` |
| `lib/core/network/control_pipeline.dart` | `ControlHandler` 多收一个 `ControlAuthorized` |
| `lib/core/storage/near_send_database.dart` | **嵌套事务改用 savepoint**（缺陷修正，见 §6） |
| `lib/core/protocol/protocol_validation.dart` | **十进制范围检查移到 `int.parse` 之前**（缺陷修正，见 §7） |
| `lib/core/protocol/chunk_headers.dart` | `Content-Length` 先剥前导零再判范围（缺陷修正，见 §7） |
| 测试 | 请求体 32 项 + 指纹 8 项 + 端点 21 项 + 嵌套事务 11 项 + 回归 6 项 |

测试规模：Flutter **888 → 957**。

## 2. 「管线可用，端点未实现」这句话到此为止

上一批（`t03-01-10`）结束时管线的处理函数表是**空的**，每个请求都答 404。
本批放进了第一个用例：§6 的「客户端为发送者：`POST /transfers` 创建 staging 任务」。
现在服务端**真的会创建一行 `STAGING` 任务**，并且有 21 项测试检查数据库而不只是响应。

## 3. 让这件事不只是「一次插入」的两条规则

**方向**：§7「客户端仅可提议 `client_to_server`；服务端发送由本地创建」。
客户端提议 `server_to_client` 被答 **403 `DIRECTION_FORBIDDEN`**，且**一行都不写**。

**`requestId`**：§9「每次操作持久化请求摘要和结果；相同 ID 不同参数拒绝 `REQUEST_ID_CONFLICT`」。
这不是可以后补的记账：没有它，一个丢了响应的客户端会重试，而服务端**无法把重试与第二个传输区分开**。
因此**效果与幂等记录在同一个事务里**由 `IdempotencyRepository.executeAtomically` 写出——
这是两者**不可能不一致**的唯一安排，也就是 `AGENTS.md` §2 规则 6 用在幂等上。

## 4. 客户端提议标识符带来的第三种情形

§7 把 `transferId` 列为请求字段，所以**由客户端选择**。于是可能出现
**不同的 `requestId` 携带一个已存在的 `transferId`**——这与重试不同，也没有 `requestId` 形状的答案：

- 已存声明**完全相同** → 客户端多半是丢了 `requestId` 在重新提议同一个传输：
  **不写任何东西而返回成功**是诚实的答案，§6 对重传清单页也持同样看法（「重传相同页返回成功」）；
- 已存声明**不同** → 这个标识符被拿去用在另一个传输上，答 **409 `INVALID_STATE`**。
  静默覆盖会毁掉另一个传输可能仍在使用的任务。

## 5. 请求摘要按**解析后的字段**计算，而不是原始字节

§9 的摘要决定重试是重放还是冲突。若按原始字节算，一个**字段顺序不同但语义相同**的重试
会被判为冲突——把一次合法重试变成 `REQUEST_ID_CONFLICT`。
因此摘要走**既有**的 `CanonicalWriter`：`transferId`(16B) + `manifestDigest`(32B) +
`fileCount`(u64) + `totalBytes`(u64) + 方向(1B)，全部定宽，不需要分隔符也不会歧义。
`requestId` **刻意不在**摘要里——它是摘要的**键**，不是参数。
方向字节按**线上值**写而不是枚举下标，这样重排枚举不会悄悄改变已存摘要。

## 6. 真实缺陷一：`transaction` 不能嵌套

端点第一次运行**每一项都失败**，报 `NS-STORAGE-006: transaction rolled back`。
根因：效果调用 `registerTask`，而它**自己开了一个事务**；`executeAtomically` 已经开了一个，
于是 `BEGIN IMMEDIATE` 在事务内被 SQLite 拒绝，然后被 `_classify` 包装成一句看不懂的回滚。

**这不是罕见形状——这正是每个幂等端点的形状**：§9 要求请求记录与效果同事务，
而效果天然会调用普通仓库方法，每个方法都会开自己的事务。所以修**这一类**而不是这一处：
嵌套的 `transaction` 改用 SQLite **savepoint**，并把 `readTransaction` 在已开事务内做成直通。

语义上必须两半都对，测试两半都覆盖：**内层失败只回滚到自己那一层且外层仍可选择提交**，
而**外层失败依旧丢弃全部**——只做对前一半的实现比不嵌套更糟，因为「部分应用的事务」
正是事务存在的意义。另外 `ROLLBACK TO` 会把 savepoint 留在栈上，
所以必须再 `RELEASE` 弹掉，否则同一层重试会因重名失败（有测试）。

## 7. 真实缺陷二与三：`int.parse` 在范围检查之前

新端点的测试发现 `parseDecimalString('9223372036854775808')` 抛的是**原始 `FormatException`**，
不是 `INVALID_DECIMAL`。§4 的模式允许**最多 19 位**，而 2^63-1 是 19 位，
所以「形状合法但超范围」的 19 位值**真的会到达解析器**，`int.parse` 直接抛异常逃逸出去。
原有测试用的是 **20 位**值，在更早的位数检查就被拦下，**从未走到解析器**，所以一直没被发现。

**影响是安全相关的**：任何经 `parseDecimalString` 解析的对端字段
（块索引、`totalBytes`、`startIndex`、`limit`、`afterSeq`、`leaseEpoch`、`checkpointSeq`、`seq`…）
都能被对端用一个 19 位数字触发未处理异常，把一次校验失败变成一条崩溃路径；
`AGENTS.md` §5 明确禁止把原始平台异常当作协议错误。

顺着同一个模式又找到**第二处**：`chunk_headers.dart` 的 `_parseContentLength`
（第十八批我自己写的）只校验「全是数字」，没有位数上界，
`Content-Length: 99999999999999999999999` 同样会抛 `FormatException`。

**修法是一处定义**：新增 `parseNormalizedDigits` 承载「按比较而非解析判范围」这一条，
`parseDecimalString` 与 `_parseContentLength` 都走它。
`Content-Length` 还**先剥前导零再判范围**，这样 `Content-Length: 000…04194304` 这种
合法 HTTP 写法（长串前导零）依旧可用，只有真正无法表示的数值被拒。

## 8. 实际执行的检查

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 格式化 | `dart format --output=none --set-exit-if-changed lib test tooling` | 通过（0 changed） |
| 静态分析 | `flutter analyze`（**未过滤输出**） | `No issues found!` |
| 全量测试 | `flutter test` | **957 passed**（888→957） |
| 端点测试 | `flutter test test/core/network/transfer_creation_handler_test.dart` | 21 passed |
| 嵌套事务测试 | `flutter test test/core/storage/near_send_database_test.dart` | 11 passed |
| 链接检查 | `python tooling/checks/check_links.py --strict` | 57 文件 / 331 链接，无断链 |
| 机密检查 | `python tooling/checks/check_secrets.py` | 298 个跟踪文件，无凭证材料 |
| CI 工作流检查 | `python tooling/checks/check_ci_workflow.py` | 不变量成立 |

两处 `int.parse` 缺陷是**先观察到失败再修**的（不是事后补测试）：修复前的运行记录就在本批的开发过程中。

## 9. 未执行与限制

1. **没有 HTTP 服务器与 TLS**：端点经管线调用，管线接收的是已经成帧的 `ControlRequest`。
2. **只有这一个端点**：19 行里其余 18 行仍答 404。
   正确描述从「管线可用，端点未实现」变为「**一个端点可用，其余 18 个未实现**」。
3. **`fileCount`/`totalBytes` 不落库**：它们是客户端的**声明**，
   而 §6 让**sealed 清单**成为「这个传输到底有什么」的权威，§7 的 `GET /offers` 从那里读摘要。
   本批只对它们做 §5 上限校验并计入请求摘要（改了就是冲突）。
4. **§6 的 30 分钟 staging 窗口未执行**（`isExpired` 仍是谓词），
   **不接收清单页**、**不 seal**、**不 decision**。
5. **`pair` 仍在 §9 幂等之外**：`t03-01-02` 登记的张力未变（§3 禁止恢复已消费的配对令牌）。
6. **协议版本协商**与**会话到任务的映射**仍未接线（沿用上一批的登记）。
7. **`readTransaction` 在已开事务内直通**：这是新语义，本批有测试，但
   「读事务里做写」仍未被拒绝（直通时不做任何事，由外层决定）。
8. **未在 Android/iOS 真机运行**；本批为纯 Dart 协议/存储/网络层。

## 10. 需要人工重点复核的区域

- **嵌套事务的 savepoint 实现**（§6）：这是本批改动的**核心语义**。
  复核重点是「外层失败是否真的丢弃内层已 RELEASE 的工作」——若 savepoint 泄漏了提交，
  就会出现「部分应用的事务」，比不支持嵌套更糟。测试覆盖了，但这是最该人工再看一遍的一处。
- **幂等记录与效果同事务**（§3、§4）：`executeAtomically` 的效果**不得**吞掉自己的异常，
  否则记录会与效果不一致。这一点只能靠代码审查。
- **凭证指纹**（§5）：作用域必须随凭证变化而不能存凭证本身。测试断言了存的是指纹，
  但「指纹不是凭证的可逆编码」是 SHA-256 的性质，属**代码审查**项。
- **两处 `int.parse` 修复**（§7）：修复方式依赖「等长十进制字符串按字典序与按数值同序」，
  前提是**已剥前导零**。若将来第三个调用点忘了剥前导零，这条推理就不成立——
  这是把范围检查收敛到 `parseNormalizedDigits` 的原因，复核时应确认没有旁路。
- **`transferId` 复用为另一传输时答 `INVALID_STATE`**：这是读法（§7 未点名），已登记。
