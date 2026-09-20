# T06-01 空间计划 — 运行汇总

- 运行 ID：`t06-01-01`
- 任务：[T06-01 空间计划、终检与导出](../../../../tasks/T06-01.md)
- 日期：2026-09-20
- 分支：`feat/t06-01-space-planning`
- 基线：`master` @ `2fa1bd9`
- 主机：Windows 10 22H2，Flutter 3.47.5 / Dart 3.13.4，SQLite 3.53.4

## 1. 本次实现的内容

| 文件 | 内容 |
| --- | --- |
| `docs/tasks/T06-01.md` | 新建任务卡（范围、验收条件、必做测试矩阵） |
| `lib/core/storage/space_plan.dart` | 空间计划模型与算法（新增） |
| `test/core/storage/space_plan_test.dart` | 36 项测试（新增） |

测试规模：Flutter **244 → 280**；存储测试 81 → 117。

本次只做 T06-01 的**第一批：空间计划**。终检（整文件摘要重算）与导出/清理属后续批次，
任务卡已登记，不假装已完成。

## 2. 规则来自哪里

空间计划不是自由设计，`技术方案 V2.1` §16.2 与 `APP_AND_SERVICE_DESIGN.md` §8 给出了完整定义。
实现逐条对应：

| 规格要求 | 实现 |
| --- | --- |
| 新增需求 = 未分配暂存 + 导出峰值额外占用 + 源暂存 + 数据库及安全余量 | `SpaceNeed` 五个枚举值，逐项一条 `SpaceLine` |
| 按实际存储卷/提供者分别核算 | `VolumeId` 值相等即同一卷；`SpacePlan.volumes` 一卷一项 |
| 同一卷并存需求相加，不同卷分别检查 | 暂存记在 `stagingVolume`，导出副本记在 `exportVolume`；同卷时两者自然相加 |
| 已有实际分配的临时文件空间不重复扣减 | `unallocatedStagingBytes = max(0, size − 已分配)`，负值钳到 0 |
| 稀疏文件逻辑长度不得视为已分配 | `stagingAlreadyAllocatedBytes` 必须由平台报告实际分配；文档明确禁止用 `sizeBytes` 推导 |
| 安全余量 = max(256 MiB, 预计新增占用的 1%)，按卷 | `SafetyMarginPolicy.forFootprint`，逐卷计算 |
| 不能只返回布尔值（§8） | 每个卷给出 `lines` 明细，`requiredBytes` 恒等于明细之和（有测试断言） |
| 无法查询 provider 空间时返回 `unknown`，不能显示「检查通过」（§8/§16.1） | `SpaceVerdict.unknown` 为一等结果；判定前先判空，不存在把缺失读数当通过的路径 |

## 3. 本次最该保留的一条不变量：`unknown ≠ sufficient`

§8 的原话是「无法查询 provider 空间时返回 `unknown`，UI 必须让用户确认风险，**不能显示「检查通过」**」。
这条规则很容易在实现里被折叠掉，所以它被做成了类型层面的性质，而不是文档里的一句话：

```dart
// 先判空，再比较：没有读数就没有「通过」这条路径
static SpaceVerdict _verdict(int requiredBytes, VolumeAvailability availability) {
  final int? free = availability.freeBytes;
  if (free == null) return SpaceVerdict.unknown;
  return requiredBytes <= free ? SpaceVerdict.sufficient : SpaceVerdict.insufficient;
}
```

并且提供的是**决策名**而不是布尔值：

```dart
bool get permitsStartWithoutUserDecision => this == SpaceVerdict.sufficient;
```

测试直接钉住这一点，包括一个「需求只有 1 字节、但 provider 查不到空间」的用例：
即使需求小到几乎不可能不足，结论**仍然不是** `sufficient`。小需求不是「装得下」的证据。

另外两条相关断言：`availability` 映射中**缺失**的卷按 `unknown` 处理（不是按 0 空间，也不是按无限空间）；
且 `unknown` **不会掩盖**另一卷的 `insufficient`——只要有卷不足，整体就是不足。

## 4. 期间发现并修正的问题

### 4.1 数据库估算常数偏小（由测试发现）

初版把每块估算定为 256 B。**「估算不得低于真实成本」这条测试当场失败**：

```text
Expected: a value greater than or equal to <53248>
  Actual: <52224>
```

实测：注册一个 200 块的文件让数据库增长 53,248 B（约 266 B/块，含文件行）。
这是本次把「估算必须保守」写成可执行断言的价值——凭直觉定的常数是错的。

修正：`defaultPerChunkBytes` 提到 320，并把测试加强为**在两个不同块数（200 与 1000）上**验证，
避免常数只是碰巧压中某一次页粒度测量。估算在实测基础上留有余量，
且该余量是刻意的（页粒度分配会让小改动多占一整页）。

### 4.2 任务卡状态与台账不一致（文档完整性问题）

`docs/tasks/README.md` 声明「任务卡中的状态必须与 `docs/PROJECT_LEDGER.md` 一致」，但实际不一致：

| 位置 | 修正前 | 修正后（依据） |
| --- | --- | --- |
| `docs/tasks/T01-02.md` | 状态「就绪 → 进行中」 | 已完成（PR #6 `9d784a4`、PR #7 `11d4304` 已在 `master` 历史中） |
| `docs/tasks/T04-01.md` | 状态「就绪」 | 进行中（PR #13/#15/#17/#19 已合并，剩余项见卡片） |
| `docs/tasks/README.md` 索引 | 只列 1 张卡（共 6 张） | 列出全部 6 张，含状态与 PR |

修正前不是靠台账推断的：用 `git log --merges` 核对了每个合并提交确实存在，
避免用一份可能同样过期的文档去「修正」另一份。

## 5. 实际执行的检查

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 格式化 | `dart format lib test tooling` | 通过 |
| 静态分析 | `flutter analyze` | `No issues found!` |
| 全量测试 | `flutter test` | **280 passed** |
| 存储测试 | `flutter test test/core/storage` | **117 passed** |
| 链接检查 | `python tooling/checks/check_links.py --strict` | 无断链 |
| 机密检查 | `python tooling/checks/check_secrets.py` | 无凭证材料 |
| CI 工作流检查 | `python tooling/checks/check_ci_workflow.py` | 不变量成立 |

## 6. 未执行与限制

1. **只有纯算法。** 平台 provider 的真实空间查询（`FileSink` 端口）、真实卷标识、
   `unknown` 的真实触发条件**都未实现**——`VolumeAvailability` 目前由调用方提供。
   不得把本文件当作「空间预检已可用」的结论。
2. **终检（整文件摘要重算）与导出/清理未实现。** 任务卡已列，属后续批次。
3. **重复检查时点未接线。** §8 要求「接收确认前、每个大文件开始前、恢复后、导出前」四个时点检查；
   本次提供的是纯函数，`plan` 随当前读数变化（有测试演示同一文件在读出不同结果时结论翻转），
   但**没有任何调度代码在调用它**。
4. **按文件的准入未实现。** §16.1 要求「空间不足时仅继续能够证明空间足够的文件」，
   这需要按当前分配滚动累加的调度，属 T05 的任务编排。
5. 未在 Android/iOS 真机运行；未验证任何真实文件系统的可用空间读数。
6. 20 GiB 用例是**算术断言**，不是真实落盘测试；真实 20 GiB 属 B07。

## 7. 需要人工重点复核的区域

- **`SafetyMarginPolicy` 的两个默认值**（256 MiB、1%）是 §16.2 给出的**可调整策略**，
  不是空间足够的保证。若调整，必须同时说明「为什么新的余量仍然够」，
  并重新审视 `space_plan_test.dart` 中断言余量为策略值而非保证的那条测试。
- **`DatabaseFootprintEstimate` 的保守性依赖当前 schema。** 只要给 `files` 或 `chunks`
  增加列或索引，实测成本就会变化；`database estimate the estimate is conservative against
  the real schema` 这条测试会在常数不再保守时失败，但**不会**在常数变得过于保守时失败
  （过度保守只是浪费用户空间，不会导致损坏，但值得复核）。
- **`VolumeId` 的取值责任在调用方。** 若平台无法给出稳定标识而调用方传了过于细的标识，
  同一物理卷会被当成两个卷分别核算，**同一份空间被检查两次**——这是本次设计中唯一会导致
  低估的入口，必须在 `FileSink` 实现时重点复核。
- **`exportPeak` 的「完整第二份副本」假设**是保守上界。若平台能证明导出是原子替换
  （先写临时后 rename，不需要额外一份），可以放宽；放宽前必须有该平台的证据。
