# T03-01 §8 批量 checkpoint 窗口与 checkpointSeq — 运行汇总

- 运行 ID：`t03-01-08`
- 任务：[T03-01 同网二维码配对与信任](../../../../tasks/T03-01.md)
- 日期：2026-09-20
- 分支：`feat/t03-01-batch-checkpoint`
- 基线：`master` @ `344f99f`
- 主机：Windows 10 22H2，Flutter 3.47.5 / Dart 3.13.4

## 1. 本次实现的内容

| 文件 | 内容 |
| --- | --- |
| `lib/core/protocol/protocol_limits.dart` | §8 的 `maxPendingCheckpointBytes`（16 MiB）与 `checkpointIntervalMillis`（1 秒） |
| `lib/core/storage/commit_window.dart` | `CommitWindowPolicy`、`ChunkCommitWindow`、`PendingChunkCommit`、`WindowPlan`（新增） |
| `lib/core/storage/storage_schema.dart` | schema **v3**：`tasks.checkpoint_seq`；`applyVersion3` |
| `lib/core/storage/storage_migrations.dart` | 注册第 3 步迁移 |
| `lib/core/storage/chunk_repository.dart` | `writeChunkThroughWindow`、`commitPendingBatch`、`checkpointSeq`；`commitChunkAfterSync` 改为经由窗口实现 |
| `test/core/storage/commit_window_test.dart` | 23 项测试（新增） |
| `test/core/storage/chunk_repository_test.dart` | 新增 14 项批量窗口测试 |
| `test/core/storage/storage_migration_test.dart` | 新增 3 项 v2→v3 断言 |
| `docs/architecture/SYSTEM_ARCHITECTURE.md` | §8 的 `tasks` 行补上 `checkpoint_seq` |

测试规模：Flutter **742 → 782**；存储层测试相应增加。

## 2. 为什么批量窗口需要存在

§8 允许接收方用 `verified_pending` 而不是 `committed` 回答块 `PUT`，并说明了理由：
「verified_pending 只证明本次块长度/摘要正确，**不可释放持久化确认跟踪**」。
字节已在盘上且摘要已验证，但**没有任何块行被提交**，所以断点没有前进。

这是一次**有意的取舍**：每块单独提交是每 4 MiB 一个事务；批量提交的代价是进程在窗口中途死亡时
丢掉上次 checkpoint 之后的工作。§8 用两道界限把这个损失框住——
待持久化有效数据**不超过 16 MiB**、等待**不超过 1 秒**——并在**暂停与文件结尾**强制提交，
因为那正是「答案不再变化」的时刻，checkpoint 最便宜。

## 3. 窗口里有意的「没有」

**没有第三种块状态。** `chunks.state` 仍然是 `missing`/`committed`。
「已写但未提交」不是进度：`AGENTS.md` §2 规则 5 让已提交行成为唯一权威，
而一个 `verifying` 状态会成为「我们到哪了」的第二个答案。
`verified_pending` 是一个**响应**，不是存储状态，所以窗口中途崩溃会把块留在 `missing`，
它们只是被重传。这条不变量由测试直接钉住：三个 `verified_pending` 之后
`committedChunkCount == 0` 且 `missingChunkIndices == [0,1,2,3]`。

**窗口持有的是「收据」，不只是索引。** 批量提交在**事务内**把每张收据与冻结清单再比对一次。
如果窗口只记索引，批量提交就成了一条「把任何已登记块标成已提交而无需证据」的路径——
这与 `commitChunkAfterSync` 当初先验证再提交的理由完全相同。
测试用一张摘要冲突的收据证明整批失败、一条都没提交、序号不前进。

**一次批量提交要么全成、要么全不成。** 半途应用的 checkpoint 会把序号推过它并未记录的工作。

**空窗口不是 checkpoint。** `commitPendingBatch` 对空窗口不开事务、不递增序号——
否则「序号 +1 却没有记录任何东西」会让发送方那句「不回退」的比对失去意义。

## 4. 「单一提交路径」被保留，而不是被并列

改造前 `commitChunkAfterSync` 是标记块为已提交的**唯一**方法。批量窗口很容易变成第二条路径，
于是把它的不变量削弱成两处各说一半。这里反过来做：
`commitChunkAfterSync` 现在**是** `CommitWindowPolicy.immediate`（窗口容量 = 一个块、间隔 = 0）
下的同一个窗口路径，所以标记 `state='committed'` 的 SQL **只有一处**——
`commitPendingBatch`。

立即策略必须用**零间隔**而不是「容量 = 一个块」来表达：文件的尾块小于一个块，
只靠容量判断它永远不会到期，于是每个文件的最后一块都会停在 `verified_pending` 而永不被提交。
测试专门覆盖了这一条。

## 5. checkpointSeq 的落点与作用域

§8 要求写入顺序里的事务提交「块标志**和** `checkpointSeq`」，§9 让接收者上报
`{leaseEpoch, checkpointSeq, committedBytes}` 并让发送方验证**不回退**。
一个只活在内存里的计数器重启后会从零开始，看起来正是一次回退，所以它必须被持久化。

**落在 `tasks` 上**，因为它的搭档 `lease_epoch`——它永远与之一起被上报和比较——就在那里。
`docs/跨平台离线文件互传系统技术方案_V2.1.md` 把 `checkpoint_seq` 放在 `sessions` 表里，
而本仓库**没有 `sessions` 表**：实现的 schema 把 `lease_epoch` 放在 `tasks`（T04-01 / ADR-0003）。
该偏离已在台账 §5 登记，需人工确认是补一张 `sessions` 表还是维持现状。
架构文档 §8 自己也写明「实际 SQL …由独立 schema 设计任务冻结」，
所以本次按已实现 schema 的最小一致改动处理。

**作用域也在 §5 登记**：§8 没有点名 `checkpointSeq` 是每任务还是每文件。
本层选**每任务**，理由同上——与 `lease_epoch` 同域。测试固定了这一点：
第二个文件的 checkpoint 取到序号 2 而不是从 1 重新开始。

## 6. v3 迁移

`ALTER TABLE tasks ADD COLUMN checkpoint_seq INTEGER NOT NULL DEFAULT 0;`
——与 v2 一样用 `ADD COLUMN` 而不是重建表：SQLite 下它是事务性的，且保留每一行。
`applyVersion1` 与 `applyVersion2` **一字未改**（现场库已经跑过它们）。
已存在的任务**合理地**没有 checkpoint，`0` 就是「尚未取过 checkpoint」的意思，
而不是一个被伪造出来的序号；测试断言升级后既有任务的 `lease_epoch` 不受扰动。
`NOT NULL` 让「尚无 checkpoint」是一个**值**而不是一种缺失，测试断言写 `NULL` 会被拒绝。

这次也**再次**自动验证了「新库与升级库的列完全一致」——该测试从 `currentVersion` 推导，
所以它随版本上移而继续生效。

## 7. 实际执行的检查

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 格式化 | `dart format --output=none --set-exit-if-changed lib test tooling` | 通过（0 changed） |
| 静态分析 | `flutter analyze` | `No issues found!` |
| 全量测试 | `flutter test` | **782 passed**（742→782） |
| 窗口测试 | `flutter test test/core/storage/commit_window_test.dart` | 23 passed |
| 存储测试 | `flutter test test/core/storage` | 通过 |
| 链接检查 | `python tooling/checks/check_links.py --strict` | 无断链 |
| 机密检查 | `python tooling/checks/check_secrets.py` | 无凭证材料 |
| CI 工作流检查 | `python tooling/checks/check_ci_workflow.py` | 不变量成立 |

## 8. 未执行与限制

1. **没有 HTTP 层**：这些方法**没有任何地方调用**。§8 的写入顺序里
   「认证和授权→文件锁」两步属端点层，本次实现的是它之后的全部步骤。
   `WireError` 仍然没有任何地方发出。
2. **每文件串行写入（§8「每文件串行写入」）未实现**：仓库不提供按 `fileId` 的异步串行化。
   当前的结构性缓解是「窗口属于单个文件」+ 事务内重检 `lease_epoch`，
   但**同一文件的两个并发写入者**仍未被结构性拒绝。需在端点层或存储层补一个每文件锁。
3. **§8 的「恢复获得相同写入栅栏，先撤销旧会话，等待旧写入停止」未接线**：
   `revokeAndAdvanceLease` 只递增世代并拒绝旧世代提交，**不等待**在途写入停止。
4. **批量窗口未做真实磁盘测量**：bound 与间隔按时钟与字节数判定，测试用假 sink 驱动，
   **没有**在真机上测量 16 MiB 窗口的实际吞吐或 1 秒间隔的实际效果。
   这与台账中 T04-01 的「批量 checkpoint 窗口与背压未测量」是同一件事，本次仍未测量。
5. **背压未实现**：§9 要求「接收端磁盘速度通过背压限制发送端」，本层只提供窗口状态，
   没有任何东西在读它来放慢发送端。
6. **未在 Android/iOS 真机运行**；本次为纯 Dart 存储/协议层，不含平台代码。
7. **`verified_pending` 的响应体仍未由任何端点发出**：`ChunkWriteState` 与
   `ChunkWriteResult` 已存在（`t03-01-06`），本次让存储层能产出两种状态，
   但把它写到线上需要 HTTP 层。

## 9. 期间发现的一处文档与现实漂移（未修改，已登记）

`lib/core/build_info/build_info.dart` 的 `kDbSchemaVersion = 1` 与
`kDatabaseImplemented = false`，使「关于」页向用户显示
「数据库 schema 版本 1（已声明，数据库尚未创建）」。

但 T04-01 已经实现了 SQLite schema 与迁移（本次之后 `currentVersion = 3`），
`dbSchemaDisplay` 的措辞与数值**都不再成立**：

- 数值上：实现的 schema 是 **3**，页面显示 **1**；
- 措辞上：「数据库尚未创建」在存储层已实现并测试之后是**不准确**的。

T01-01 的任务卡自己要求「`kDbSchemaVersion` …各自只有一个定义处；其它层只能消费，**不得重复定义**」，
而现在已经有了**两处**定义（`kDbSchemaVersion` 与 `StorageSchema.currentVersion`）。

**本批不擅自改**，因为它需要先回答一个语义问题：`kDatabaseImplemented` 指的是
「存储层已实现」还是「运行中的应用真的会打开一个数据库」（目前 `NearSendApp` 没有打开）。
两者结论不同，且这是 T01-01 的产物。已在台账 §5 登记并提出两个候选解法。

## 10. 需要人工重点复核的区域

- **批量提交的事务边界**：一次 checkpoint 内多条 `UPDATE chunks` 加上 `checkpoint_seq + 1`
  必须同事务。半应用的 checkpoint 会谎报进度，这是本层最该被复核的一处。
- **收据再校验**：批量路径把「验证」与「提交」分成两次调用，
  而原来的单块路径是同一次。收据里带摘要是让这件事仍然安全的结构，
  但**调用方必须真的把 sink 报告的摘要放进收据**——这一点只能靠代码审查确认。
- **`checkpointSeq` 的作用域与落点**（见 §5）：每任务 vs 每文件、`tasks` vs `sessions`。
- **1 秒间隔的语义**从**首个待提交块**起算，而不是从最近一次提交或最近一次入队起算。
  测试固定了「从第一个块起算」，若对端按别的起算点理解，双方会在「该不该已经 checkpoint」上分歧。
- **v3 迁移对既有库的影响**：`ADD COLUMN NOT NULL DEFAULT 0` 对已有行写入 0。
  这是**读法**：既有任务确实没有取过 checkpoint。若协议要求既有任务继承某个非零序号，需改。
- **`kDbSchemaVersion` 漂移**（见 §9）：需先定语义再改。
