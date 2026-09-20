# T04-01 磁盘满与提交失败注入 — 运行汇总

- 运行 ID：`t04-01-05`
- 任务：[T04-01 SQLite schema、迁移框架与 chunk repository](../../../../tasks/T04-01.md)
- 日期：2026-09-20
- 分支：`feat/t04-01-disk-full-injection`
- 基线：`master` @ `ffeb6a3`
- 主机：Windows 10 22H2，Flutter 3.47.5 / Dart 3.13.4，SQLite 3.53.4

## 1. 本次实现的内容

| 文件 | 内容 |
| --- | --- |
| `lib/core/storage/storage_failure.dart` | 新增 `NS-STORAGE-008 spaceInsufficient` 并修正映射与可重试性 |
| `lib/core/storage/near_send_database.dart` | 在抛出点区分 `SQLITE_FULL` 与一般提交失败 |
| `test/core/storage/storage_failure_injection_test.dart` | 8 项注入测试（新增） |
| `test/core/storage/storage_migration_test.dart` | 固定新错误码的映射与可重试性 |

测试规模：Flutter **236 → 244**；存储测试 73 → 81。

## 2. 先做探针，再决定怎么注入

本次没有直接假设「怎么模拟磁盘满」，而是先写探针（已删除，结论如下）实测引擎行为。
两个结论决定了后面的实现方式，其中一个是否定结论。

### 探针 1：`max_page_count` 确实产生真实的空间耗尽

把 `PRAGMA max_page_count` 钉在当前页数后继续写入，引擎真实返回

```text
SqliteException(13): while executing statement, database or disk is full ... (code 13)
```

**result code 13 就是 `SQLITE_FULL`**。这是引擎自己报的错，不是替身抛出来的异常，
因此本次的磁盘满条件**不是模拟**。失败的 INSERT 事务整体回滚，数据库停在「恰好满」的状态，
后续写入继续失败（探针已验证），状态稳定可复现。

### 探针 2（否定结论）：块提交本身无法被空间耗尽打到失败

即使数据库**完全写不进去**，`UPDATE chunks SET state='committed' …` **依然成功**。
原因很直接：这条语句改写已有行，不需要分配新页，`max_page_count` 约束不到它。

所以**无法**通过耗尽页数让 `commitChunkAfterSync` 在自己的提交语句上失败。
这个否定结论改变了注入的位置：

> 在真实产品里，把磁盘写满的是 **sink 写入的块数据**，不是数据库行。
> 因此「磁盘满」的真实表现是 **sink 写不进去**，而数据库侧的满条件必须单独处理。

## 3. 期间修复的缺陷：磁盘满被报告为「可重试」

`NearSendDatabase.transaction` 把任何非 `StorageException` 的失败一律包装成
`StorageFailureCode.commitFailed`。于是上面那个真实的 `SQLITE_FULL` 到达调用方时是：

| | 修复前 | 修复后 |
| --- | --- | --- |
| 本地码 | `NS-STORAGE-006 commitFailed` | `NS-STORAGE-008 spaceInsufficient` |
| 线路码 | `DB_COMMIT_FAILED` | `SPACE_INSUFFICIENT` |
| HTTP | 500 | 507 |
| `retryable` | **true** | **false** |

修复前 `retryable: true` 意味着客户端会**对着一个写不进去的卷无限重试**，
而且 §11 为 `SPACE_INSUFFICIENT` 规定的唯一有效动作——「清理空间或更换位置，然后重试」——
永远不会被呈现给用户：错误被报成了它不需要用户做任何事的那一类。

修复是在抛出点比较 SQLite 的**主结果码**（`resultCode == 13`）。只映射这一条，
不预先为没有测试覆盖到的错误码编造映射；扩展码把主码放在低字节，
所以 `resultCode` 对 `SQLITE_FULL` 的所有变体都成立。

## 4. 已验证行为

### 4.1 真实的卷满

| 断言 | 结果 |
| --- | --- |
| 卷满报为 `spaceInsufficient`，`SPACE_INSUFFICIENT`，507，**不可重试** | 通过 |
| 异常 `cause` 是 result code 13 的 `SqliteException`（引擎产生，非模拟） | 通过 |
| 被拒绝的写入**没有留下半行**（回滚完整） | 通过 |
| 卷满之前已提交的块**仍然是 committed**，缺失块查询只列未完成项 | 通过 |
| 同一事务内「块提交 + 一次必然分配空间的写入」被卷满打断后，**块不是 committed** | 通过 |
| 释放空间后，同一项工作成功 | 通过 |

最后两条直接对应验收矩阵的「磁盘满 → 提交失败且不产生 committed；保留可恢复状态」。
倒数第三条是本次最重要的回归保护：卷满**不得让接收方丢掉已提交的断点**。

### 4.2 提交被拒绝

| 断言 | 结果 |
| --- | --- |
| durable sync 失败 → 不确认任何内容（无 committed 块、`isFullyCommitted` 为假、任务状态未变） | 通过 |
| 被拒绝的提交**不消耗写入世代**：同一 `lease_epoch` 仍可授权重试并成功 | 通过 |
| 失败后块行仍是 `missing`，`committed_at` 为 NULL，期望摘要仍来自冻结清单 | 通过 |

第二条是有实际意义的：如果一次瞬时写失败就烧掉写入世代，用户会为了一个可重试的
写失败被迫走一次完整恢复流程。

## 5. 实际执行的检查

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 格式化 | `dart format lib test tooling` | 通过 |
| 静态分析 | `flutter analyze` | `No issues found!` |
| 全量测试 | `flutter test` | **244 passed** |
| 存储测试 | `flutter test test/core/storage` | **81 passed** |
| 链接检查 | `python tooling/checks/check_links.py --strict` | 40 个 Markdown、211 条链接，无断链 |
| 机密检查 | `python tooling/checks/check_secrets.py` | 231 个受跟踪文件，无凭证材料 |
| CI 工作流检查 | `python tooling/checks/check_ci_workflow.py` | 不变量成立 |

## 6. 未执行与仍然存在的限制

1. **没有在真实满盘的文件系统上运行。** 本次的卷满条件由 SQLite 引擎产生
   （`max_page_count` 耗尽页分配），它产生真实的 `SQLITE_FULL`，但**不等于**
   操作系统在写入过程中返回 `ENOSPC`：没有真实的文件系统配额、没有部分写入的块文件、
   没有 WAL 文件本身写满的情形。**不得**把本文件当作真实满盘结论。
2. **sink 失败是替身。** §4.2 的 `_FailingSink` 是我们自己抛的异常，用于验证「sink 失败
   → 不提交」这条顺序保证。它停留在 `DurableChunkSink` 这个明确的平台端口上，
   但没有触及任何真实平台写入路径。
3. **真实暂存文件损坏/丢失仍未注入**（依赖 T06-01 的暂存层）。
4. **断电耐久性仍未证实**（B04 真机验证）。
5. **`DurableChunkSink` 的端口契约仍写「任何步骤失败都抛 `commitFailed`」**，
   而卷满时更诚实的码是 `spaceInsufficient`。本次没有改动该契约：
   具体实现属于 T06-01，现在定契约会替它做未经实现验证的决定。
   **已在 §7 登记为待复核项。**

## 7. 需要人工重点复核的区域

- **`_classify` 的映射范围**：目前只把主结果码 13 映射为空间耗尽。
  未被映射的引擎错误（如 `SQLITE_READONLY`、`SQLITE_IOERR`、`SQLITE_CORRUPT`）
  仍会落到「可重试的提交失败」，这在语义上未必正确。**需要人工判断是否逐项映射**，
  本次不凭推测扩充。
- **`spaceInsufficient` 的不可重试性**：由 `storage_migration_test.dart` 的
  「只有失败的提交可重试」循环断言固定。若将来要让空间耗尽参与自动重试，
  必须同时修改该断言并说明「空间何时被释放」的判断依据。
- **`DurableChunkSink` 契约与空间耗尽的用码**（见 §6.5）。
- **块提交不需要分配空间**这一结论依赖当前 schema 与索引；
  若将来给 `chunks` 增加列或索引，结论可能改变，注入方式需要重做。
