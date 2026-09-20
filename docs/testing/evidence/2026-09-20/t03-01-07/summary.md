# T03-01 §8 请求头与体规则 — 运行汇总

- 运行 ID：`t03-01-07`
- 任务：[T03-01 同网二维码配对与信任](../../../../tasks/T03-01.md)
- 日期：2026-09-20
- 分支：`feat/t03-01-chunk-headers`
- 基线：`master` @ `e6a4d22`
- 主机：Windows 10 22H2，Flutter 3.47.5 / Dart 3.13.4

## 1. 本次实现的内容

| 文件 | 内容 |
| --- | --- |
| `lib/core/protocol/chunk_headers.dart` | §8 的块请求头校验、块体长度规则、块响应头（新增） |
| `test/core/protocol/chunk_headers_test.dart` | 40 项测试 |
| `lib/core/storage/storage_failure.dart` | 修正 `syncReceiptMismatch` 的线路码映射（见 §9） |
| `test/core/storage/storage_migration_test.dart` | 固定该映射 |

测试规模：Flutter **702 → 742**；协议层测试 341 → 381。

## 2. 为什么把这些规则做成纯函数

§8 的这些是**帧定界规则**，而请求走私就住在帧定界里：
一条两个跳数对「它在哪里结束」有分歧的消息，是一条可以被切成两条的消息。

把它们放在一个**对收到时的头映射求值的纯函数**里，而不是放在 HTTP 处理函数内部，
有两个直接好处：判定与「读 body」彻底分离（**帧不合法的消息一个字节都不会被处理**），
而且**不需要 socket 就能完整测试**。

## 3. 「单一 Content-Length」在头映射里意味着什么

头映射无法把同一个名字放两次，所以一个重复的头会以两种形态出现，**两种都被拒绝**：

1. 两个只差大小写的条目（`Content-Length` 与 `content-length`）——
   HTTP 字段名大小写不敏感，**悄悄合并就会替实现选一个长度**，而选哪一个正是这条规则要防的分歧；
2. 一个用逗号连接的值（`4194304, 1`）——这就是一个对端在**说存在两个长度**。

`Transfer-Encoding` 的任何取值都被拒绝（含 `identity`），§8 还点名了
「`Content-Length` 与 `Transfer-Encoding` 同时出现」这一组合。
压缩同样：`Content-Encoding` 只接受缺省或 `identity`。

**前导零被接受**，这是有意的层次划分：`Content-Length` 是 **HTTP 字段**，
按 HTTP 的文法是一串数字；§4 的规范十进制形式是**协议字段**的规则。
解析出来的**值**才是与清单比对的东西，所以 `0004194304` 与 `4194304` 没有区别。
这一点在文档与测试里都写明了，以免被误当成疏漏。

## 4. 只有本项目自己的命名空间才被拒绝

HTTP 带着大量与本协议无关的头（`User-Agent` 等），**全部拒绝是错的**。
但 `X-LFT-` 前缀是本项目的，所以那里的未定义头被拒绝——
理由与 §4 拒绝未定义 JSON 字段相同：**一个实现遵守、另一个实现丢弃的参数，
是任何一方的测试都抓不到的行为差异**。

## 5. 冻结清单是权威，头里的摘要不是

§8：「服务端 GET 返回 Content-Length 和 X-LFT-Chunk-SHA256；**接收者仍以冻结清单为权威**」。

`agreesWithManifest` 报告对端的说法是否与清单一致，**但不把不一致变成拒绝**：
若在**参考性**字段上拒绝，等于把一个对端本来影响不了的下载失败权交给它。
测试同时断言「不一致被如实报告」与「头里的值仍被如实保留」。

## 6. 块体必须恰好是预期长度

§8：「body 长度必须等于该块预期长度，**末尾额外数据拒绝并关闭连接**」。

短的决定是「消息提前结束」（**可能正是因为两个跳数对帧定界有分歧**），
长的则是「在声明的块之后又追加了字节」。两者都以 `INVALID_FIELD` 拒绝——
§11 把该码配以「**修正请求，不自动原样重试**」，这正是帧定界错误应有的指示：
原样重发只会重演同一次分歧。

## 7. 实际执行的检查

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 格式化 | `dart format lib test tooling` | 通过 |
| 静态分析 | `flutter analyze` | `No issues found!` |
| 全量测试 | `flutter test` | **742 passed** |
| 协议层测试 | `flutter test test/core/protocol` | **381 passed** |
| 链接检查 | `python tooling/checks/check_links.py --strict` | 无断链 |
| 机密检查 | `python tooling/checks/check_secrets.py` | 无凭证材料 |
| CI 工作流检查 | `python tooling/checks/check_ci_workflow.py` | 不变量成立 |

## 8. 未执行与限制

1. **没有 HTTP 层**：这些函数**没有任何地方调用**；没有连接处理、没有 TLS、
   没有 body 读取、没有响应写出。「拒绝并关闭连接」的**关闭**那一半需要 HTTP 层才能实现。
2. **`X-LFT-Lease-Epoch` 用 §4 的规范十进制校验是本读法**：
   一个头可以合法地写成 `0003`。本层拒绝它，理由是让一个世代只有一种拼写
   （见 §9）。**需确认**。
3. **`Content-Type` 不接受参数**：`application/octet-stream; charset=binary` 被拒绝。
   §8 的措辞是「要求 `Content-Type: application/octet-stream`」，本层按**恰好**理解。
   两端都由本项目实现，故可接受，但它是一条**可能影响互操作**的严格读法。
4. **§8 的写入顺序未接线**：认证→文件锁→再次检查 epoch→写入并验证→待提交队列→`syncData`
   →事务提交→发布。其中「写入→摘要→sync→事务提交」已由 T04-01 的
   `commitChunkAfterSync` 实现，但**完整顺序需要端点逻辑**，尚未存在。
5. **§8 的批量 checkpoint 规则未实现**：「最多 16 MiB 待持久化有效数据」、
   「每 16 MiB 或 1 秒 checkpoint」、「暂停/文件结尾强制提交」。
   这与台账中 T04-01 的「批量 checkpoint 窗口与背压未测量」是同一件事。
6. **§8 的「重复已提交块必须校验世代、长度和内容」已在实质上满足，但错误码原先不对**：
   见 §9 第 1 条——已在本批修正。
7. 未在 Android/iOS 真机运行。

## 9. 期间发现并修正的一个真实缺陷

§8 要求：**「重复已提交块必须校验世代、长度和内容；内容冲突返回 `CHUNK_HASH_MISMATCH`，
不可因『已有块』就无条件成功」**。

追查 `commitChunkAfterSync` 后确认：**校验本身是有的**——
它把 sink 报告的摘要与**冻结清单**里该块的摘要比较，
所以一个内容不同的重传**会被发现**（这正是 §8 要的，且权威来源正确）。

**但错误码是错的**：那条路径抛 `syncReceiptMismatch`（`NS-STORAGE-004`），
而该码在 `StorageFailureCode.protocolCode` 里**没有映射**，
于是 `StorageException.toProtocolError()` 会走它的兜底分支
`code.protocolCode ?? ProtocolErrorCode.dbCommitFailed`，把结果报成
**`DB_COMMIT_FAILED`（500，`retryable: true`）**。

后果是具体的：§11 把 `DB_COMMIT_FAILED` 配以「可重试」，
而 §8 为内容冲突指定的是 **`CHUNK_HASH_MISMATCH`（422，不可重试）**，
§11 对它的指示是「阻断或按正确来源修复，**不无限重试**」。
也就是说，**当前行为会邀请客户端无限重发一个内容与清单冲突的块**——
正是 §8 与 §11 各自禁止的事。

修正：`syncReceiptMismatch` 现在映射到 `ProtocolErrorCode.chunkHashMismatch`（422），
并在 `storage_migration_test.dart` 里断言映射本身、其 422 状态码与不可重试性。

这个缺陷是**把 §8 的文字与存储层实际行为对照**才发现的：
两边的测试各自都是绿的，因为存储层的测试只断言了本地错误码，
而协议层的表测试只覆盖了它自己列出的码。

## 10. 需要人工重点复核的区域

- **`toProtocolError` 的兜底分支**：`code.protocolCode ?? ProtocolErrorCode.dbCommitFailed`
  会为**故意没有映射**的码发明一个线路码。本批修好了 `syncReceiptMismatch`，
  但 `schemaTooNew` / `migrationFailed` / `backupFailed` 仍会以 `DB_COMMIT_FAILED` 报出——
  而它们在本层的文档里被明确描述为「never reaches the peer」的本地拒绝。
  **这属于需要显式决定的设计问题**（是抛错、还是定义一个通用的内部错误码），
  本批不擅自设定；目前没有调用方，所以是潜在问题而非现行缺陷。
- **`X-LFT-Lease-Epoch` 的规范拼写**（见 §8.2）：本层拒绝前导零。若与对端的实现不一致，
  对齐会浪费一次往返。
- **`Content-Type` 是否允许参数**（见 §8.3）：本层按「恰好」理解。
- **拒绝 `Transfer-Encoding: identity`** 是保守读法：§8 说「不支持 `Transfer-Encoding`」，
  本层按「出现即拒绝」理解，没有为 `identity` 开例外。
- **本层不校验块索引与 offset**：那由 §7 的 `chunkOffsetBytes` 负责（已实现并有测试），
  两者尚未在同一处串起来。
- **`assertChunkBodyLength` 的码选择**：§8 未指定错误码，本层选 `INVALID_FIELD`（400）
  而非 `CHUNK_HASH_MISMATCH`（422），理由是帧定界错误需要**修正请求**而不是**从正确来源修复**。
  需确认。
