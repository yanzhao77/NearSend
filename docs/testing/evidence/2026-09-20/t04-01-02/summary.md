# T04-01 存储核心实现 — 运行汇总

- 运行 ID：`t04-01-02`
- 任务：[T04-01 SQLite schema、迁移框架与 chunk repository](../../../../tasks/T04-01.md)
- 日期：2026-09-20
- 分支：`feat/t04-01-storage-core`
- 基线：`master` @ `e5eee45cfd404ebcb31da3bfb69d71c8d770e4d6`
- 主机：Windows 10 22H2，Flutter 3.47.5 / Dart 3.13.4，SQLite 3.53.4

## 1. 本次实现的内容

| 文件 | 职责 |
| --- | --- |
| `lib/core/storage/storage_schema.dart` | schema v1：`schema_info`、`tasks`、`files`、`chunks`、`peers`、`idempotency`、`exports` 与索引 |
| `lib/core/storage/storage_failure.dart` | 存储本地失败码（`NS-STORAGE-*`）、可重试性、以及到协议错误码的映射 |
| `lib/core/storage/storage_migrations.dart` | 迁移注册表与运行器、逐步事务、一致性备份、高版本拒绝 |
| `lib/core/storage/near_send_database.dart` | 打开与 PRAGMA、版本守卫、事务辅助 |
| `lib/core/storage/chunk_repository.dart` | 任务/文件登记、块状态、**提交顺序**、缺失块权威查询、写入世代仲裁 |
| `test/core/storage/*` | 38 项测试（迁移 20、块仓库 18） |

测试规模：Flutter 测试 **168 → 201**。

## 2. 关键设计：让错误顺序难以表达

### 2.1 提交顺序由接口形状强制

`ChunkRepository.commitChunkAfterSync` 是**唯一**能把块标记为 committed 的方法，而它必须接收一个
`DurableChunkSink`。它按协议 §8 的顺序执行：

```
读取冻结清单中的期望 offset/length/sha
  → 校验 lease_epoch（写入前）
  → 校验字节长度与清单一致
  → sink 写入 + 分块摘要校验 + durable sync
  → 校验 sink 回报的长度与摘要与清单一致
  → 事务内再次校验 lease_epoch → 提交
```

调用方无法「先提交再同步」：没有只接受已同步证明的公开方法，也没有任何方法绕过 sink。

### 2.2 世代在提交事务内二次校验

§8 指出只在请求入口检查 epoch 不够，因为旧写入可能在恢复之后继续落盘。
测试 `a resume that lands mid-write prevents the commit` 在 sink 写入期间调用
`revokeAndAdvanceLease`，然后断言提交被拒绝且块仍为 `missing` —— 这正是那个窗口。

### 2.3 没有字节计数

`chunks` 表只有 `state ∈ {missing, committed}`，**刻意没有** `received_bytes`/`written_bytes` 列。
`missingChunkIndices` 是唯一的恢复查询，它只读块状态。`AGENTS.md` §2 规则 5 要求恢复不能依据
字节计数，那么最稳妥的做法是这个数字在存储层根本不存在。

### 2.4 高版本 schema 拒绝且不写

`PRAGMA journal_mode = WAL` 会写进数据库头（`synchronous`/`foreign_keys` 只是连接级），
所以版本检查被放在**应用任何 PRAGMA 之前**。测试用 `PRAGMA journal_mode` 读回 `delete`
来证明拒绝路径**没有修改文件**——这比「抛出异常了」强得多。

## 3. 测试覆盖的故障窗口

`QUALITY_AND_ACCEPTANCE.md` §3 要求注入的窗口与本次覆盖情况：

| 窗口 | 覆盖 | 结果 |
| --- | --- | --- |
| 写入前崩溃 / 参数不符 | 长度与清单不符在写入前被拒绝，sink 调用次数为 0 | 通过 |
| sync 前/中失败 | sink 抛错 → 块保持 `missing` | 通过 |
| 写入内容不符 | sink 回报错误摘要 → `syncReceiptMismatch`，块保持 `missing` | 通过 |
| 长度不符 | sink 回报错误长度 → 同上 | 通过 |
| DB 提交前崩溃 | 提交事务内行消失 → 提交失败 | 通过 |
| 提交后崩溃 / 设备重启 | 关闭并重新打开数据库后 committed 与 lease_epoch 均持久 | 通过 |
| 损坏块识别 | `markChunksMissing` 使块退回 `missing`，`isFullyCommitted` 变为 false | 通过 |
| 旧 lease 写入 | 旧世代提交被拒绝，块保持 `missing` | 通过 |
| 迁移中途失败 | 步骤抛错 → 版本不前进、事务内建的表不残留、数据库仍可再次迁移 | 通过 |
| 高版本 schema | 拒绝打开且文件未被修改 | 通过 |

## 4. 过程中发现并修复的一个真实缺陷

`writeBackup` 原先在 `try` 之外创建备份目录，因此目标不可写时抛出的是原始
`PathExistsException` 而不是 `StorageException(backupFailed)`。**调用方唯一需要处理的失败条件
却拿到了未类型化的异常**。测试 `an unwritable destination is reported as backupFailed`
发现并固定了这一点，修复方式是把目录创建移入 `try`。

## 5. 未完成 / 未覆盖（本任务**尚未**达到退出门槛）

T04-01 在台账中保持**进行中**，因为下列范围内事项尚未实现：

1. **幂等记录的持久化未实现**。T02-02 已在内存中固定了 `request_id` 规则，
   但「与效果在同一事务提交」的持久化版本仍未写；验收条件中该项未勾选。
2. **`peers`/`exports` 表已建但无仓储方法**；`tasks`/`files` 只有登记与读取，尚无状态迁移与导出记录。
3. **磁盘满（ENOSPC）未注入**。可移植地制造 ENOSPC 需要受限卷或平台特定手段，本机未做；
   当前只覆盖了「提交失败不确认」的通用路径。
4. **真实暂存文件损坏/丢失未测**。`markChunksMissing` 覆盖了状态迁移与查询，
   但真实文件的损坏检测需要暂存层（T06-01）。
5. **平台 `syncData` 真实语义未验证**（B04）。本次的 sink 是测试替身；
   真机断电耐久性仍未证实，**不得**据本文件声称写入耐久性已验证。
6. **迁移只存在 v1**，因此「从任意历史版本迁移」目前退化为 0→1；框架与回滚已按多步设计并有测试，
   但真正的多版本迁移要等 schema v2 出现才能端到端验证。

## 6. 已知限制

- 测试使用较小的 `chunkSizeBytes`（4 字节）以便快速构造多块场景；协议固定的 4 MiB
  另有一条独立测试（4 MiB + 3 字节 → 恰好 2 块，尾块 offset 为 4 MiB，验证 64 位运算）。
- 未做性能测量（批量 checkpoint 窗口与背压属 T04 的后半段）。
- 未在 Android/Windows 真机运行；本机是 Windows 桌面测试环境。
