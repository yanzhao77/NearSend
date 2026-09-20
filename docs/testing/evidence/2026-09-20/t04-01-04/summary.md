# T04-01 任务/文件状态与导出、peer 授权 — 运行汇总

- 运行 ID：`t04-01-04`
- 任务：[T04-01 SQLite schema、迁移框架与 chunk repository](../../../../tasks/T04-01.md)
- 日期：2026-09-20
- 分支：`feat/t04-01-transfer-peers`
- 基线：`master` @ `0ef4903`
- 主机：Windows 10 22H2，Flutter 3.47.5 / Dart 3.13.4，SQLite 3.53.4

## 1. 本次实现的内容

| 文件 | 内容 |
| --- | --- |
| `lib/core/storage/transfer_repository.dart` | 任务/文件状态持久化、导出记录（新增） |
| `lib/core/storage/peer_repository.dart` | peer 身份指纹与用户授权（新增） |
| `lib/core/storage/near_send_database.dart` | 事务错误类型修复（见 §4） |
| `test/core/storage/transfer_repository_test.dart` | 12 项测试（新增） |
| `test/core/storage/peer_repository_test.dart` | 10 项测试（新增） |

测试规模：Flutter **214 → 236**；存储测试 51 → 73。

## 2. 状态迁移不绕过 T02-02 状态机

`transitionTask` / `transitionFile` 在**写入新状态的同一个事务内**读取当前状态并调用
`TransferStateMachine.assertTransition` / `FileStateMachine.assertTransition`。
未定义的边抛 `ProtocolViolation(INVALID_STATE)` 且不写任何内容。

这不是形式检查。§10 只规定了部分边（例如只写了「网络断开→INTERRUPTED」而没写来源状态），
T02-02 已经把这些缺口显式登记为缺口。如果仓储层自己决定接受哪些边，协议层登记的缺口就会
在存储层被悄悄填平，两个实现在「任务是否可续传」上分叉。

测试覆盖：

- 已定义的边被写入（`ready → transferring`）；
- 未定义的边被拒绝，且状态**保持不变**（`ready → completed`、`pending → completed`）；
- `skipped` 为终态，离开它被拒绝；
- 一整条已定义路径可以走通（`ready → … → completed`）；
- 未知任务被报告为错误，而**不是**被顺手创建。

## 3. 导出记录：两个「不许发生」

### 3.1 未全部 committed 的文件不得记录导出

`recordSavedExport` 在写入导出行的同一事务内统计 `chunks` 中 committed 的数量，
与 `files.chunk_count` 比对，不一致即抛 `NS-STORAGE-007`。
若只在别处（或调用前）检查，一次崩溃就能让「文件已保存」的结论落在缺块的文件上——
这正是「假完成」。

测试用真实的 `commitChunkAfterSync` 提交 2 块中的 1 块，断言导出被拒绝、
`exports` 无行、文件仍停在 `exporting`。

### 3.2 同一文件不得静默产生第二份副本

| 情况 | 行为 |
| --- | --- |
| 同一目标重复记录 | 幂等：返回**原有行**（`recorded_at` 不变，`exports` 仍只有 1 行） |
| 已保存后记录**不同**目标 | 拒绝（§10 禁止在结果未知时盲目再产出一份） |
| 已保存后记录一次失败 | **不覆盖**已保存记录——用户那份副本仍然存在 |

「先失败后成功」是允许的：失败记录让文件停留在 `exporting`（可重试），
成功后同事务把文件推进到 `completed`。

## 4. 期间修复：`transaction` 把协议错误改写成了存储错误

`NearSendDatabase.transaction` 会把任何非 `StorageException` 的失败包装成
`StorageException(commitFailed)`。而状态机拒绝一条未定义的边时抛的是 `ProtocolViolation`，
于是调用方收到的是 `NS-STORAGE-*`——**它被告知磁盘失败了，实际是协议拒绝了**。
按错误码做重试/降级的调用方会据此做出错误判断。

修复：`transaction` 与 `readTransaction` 现在原样重抛 `ProtocolViolation`，
与 `StorageException` 同等处理；回滚行为不变，真正意外的错误仍被包装并保留 `cause`。

这个缺陷是本次新测试发现的，本地此前的 214 项测试没有覆盖到，
因为在此之前没有任何被测代码路径会从 `transaction` 内部抛出 `ProtocolViolation`。

## 5. peer 授权：指纹变化只报告、不吸收

`trustFor` 不返回布尔值，而是区分四种情况，因为「指纹变了」必须**开启重新配对流程**
而不是让请求失败，「我们撤销过这台设备」与「从没见过它」也需要不同的界面：

| 情况 | 返回 |
| --- | --- |
| 无记录 | `unknown` |
| 指纹匹配且已授权 | `authorized` |
| 指纹不匹配 | `fingerprintChanged` |
| 已撤销 | `revoked` |

关键断言：评估一次不匹配的指纹**不修改任何存储内容**——被呈现的指纹不会被静默采纳，
peer 的授权状态也不变。只有 `recordUserAuthorization`（名字即断言：这是**用户**的决定）
才改变已存信任。这挡住了「谁能占据该 peer 的地址，谁就继承它的授权」。

重装路径也验证了：已授权 peer 以新指纹出现时返回 `fingerprintChanged`，
需要重新配对，即使它此前被授权过。

`peers` 表结构被测试固定为 `peer_id, display_name, identity_fingerprint, authorized,
last_seen_at`，并断言其中**没有** token/key/secret/password 列——`AGENTS.md` §5 要求
凭证只进平台安全存储，这条断言让「顺手加一个令牌列」无法悄悄通过。

## 6. 实际执行的检查

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 格式化 | `dart format lib test tooling` | 通过（3 个文件被格式化后无差异） |
| 静态分析 | `flutter analyze` | `No issues found!` |
| 全量测试 | `flutter test` | **236 passed** |
| 存储测试 | `flutter test test/core/storage` | **73 passed** |
| S0 探针 | `python -m unittest discover -s tooling/s0 -p "test_*.py"` | **24 passed** |
| 链接检查 | `python tooling/checks/check_links.py --strict` | 39 个 Markdown、204 条链接，无断链 |
| 机密检查 | `python tooling/checks/check_secrets.py` | 229 个受跟踪文件，无凭证材料 |
| CI 工作流检查 | `python tooling/checks/check_ci_workflow.py` | 不变量成立 |

### 环境说明（非仓库缺陷）

`tooling/s0` 的 TLS 用例在本机需要 `OPENSSL_CONF` 指向有效的 `openssl.cnf`。
本机唯一的 `openssl.exe` 来自 Anaconda，其内置配置路径
（`D:\bld\openssl_split_...\_h_env\Library/openssl.cnf`）不存在，导致
`openssl req` 失败、`TLSTests.setUpClass` 报错。设
`OPENSSL_CONF=C:\data\python\anaconda3\Library\openssl.cnf` 后 24/24 通过。
CI 在 ubuntu 上不受影响。

## 7. 未执行与仍剩余

本次只解决了任务卡「仍剩余」列表的第 1 项。仍未完成：

1. **磁盘满（ENOSPC）注入** — 未做。
2. **真实暂存文件损坏/丢失** — 依赖 T06-01 的暂存层。
3. **平台 `syncData` 真机语义（B04）** — 真机断电耐久性**未证实**。
4. **多版本迁移** — 目前只有 schema v1，0→1 之外的路径无法端到端验证。
5. **批量 checkpoint 窗口与背压** — 未测量。

## 8. 已知限制

- 全部结论来自 Windows 桌面进程内的真实 SQLite 文件；**未在 Android/iOS 真机运行**，
  因此本文件中的任何结果都**不能**作为真机耐久性结论。
- 事务隔离结论依赖单连接；未在多连接下测量 `busy_timeout` 与锁等待行为。
- `transfer_repository_test.dart` 中的 `_DirectSink` 只报告正确摘要、不写字节，
  因此它验证的是状态与导出逻辑，**不是**写入路径。
- 后台 isolate 模型仍未冻结（`SYSTEM_ARCHITECTURE.md` §12）。

## 9. 需要人工重点复核的区域

- `_assertFullyCommitted` 的「全部 committed」判据是导出与「假完成」之间的唯一屏障；
- `recordSavedExport` 对**不同目标**的拒绝策略是安全默认值，产品若要支持
  「另存一份」必须显式设计确认流程，不得放宽此处；
- `recordFailedExport` 不覆盖已保存记录的前提是「用户那份副本确实还在」——
  若平台导出实际上是「移动」语义，此前提不成立；
- peer 指纹变化的重新配对入口目前只有仓储层，**没有**任何调用方，
  UI 层必须在实现配对流程时接上它才能生效。
