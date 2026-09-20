# T06-01 整文件终检 — 运行汇总

- 运行 ID：`t06-01-02`
- 任务：[T06-01 空间计划、终检与导出](../../../../tasks/T06-01.md)
- 日期：2026-09-20
- 分支：`feat/t06-01-verification`
- 基线：`master` @ `b41e96f`
- 主机：Windows 10 22H2，Flutter 3.47.5 / Dart 3.13.4，SQLite 3.53.4

## 1. 本次实现的内容

| 文件 | 内容 |
| --- | --- |
| `lib/core/storage/file_verification.dart` | `StagedChunkReader` 端口、`FileVerificationResult`、`FileVerifier`（新增） |
| `test/core/storage/file_verification_test.dart` | 22 项测试（新增） |

测试规模：Flutter **280 → 302**；存储测试 117 → 139。

## 2. 一次流式读取回答两个不同的问题

终检要回答两个问题，它们**不是**同一个问题：

- **这个文件是不是发过来的那个文件？** —— 整文件摘要，也是导出的闸门
  （端侧设计 §7：「全部 committed 后重新计算整文件摘要。摘要一致才允许导出。」）
- **哪一部分是坏的？** —— 分块摘要。为了修一个坏块而重传 20 GiB 不是恢复策略。

两个答案来自**同一次有序读取**：每块既单独哈希，又同时喂给累积的整文件摘要。
读两遍会让这条「经过用户收到的每一个字节」的路径 I/O 翻倍。
测试分别钉住了这两件事——`chunks are read in ascending order` 断言读取顺序确实是 0,1,2，
因为顺序正是整文件摘要成立的前提：顺序错了是正确性缺陷，不是性能问题。

## 3. 内存有界

字节以流的形式消费，**从不累积**，唯一增长的是 SHA-256 状态。
把整文件缓冲下来再哈希会违反 `AGENTS.md` §2 规则 4，而且在 20 GiB 上会直接失败。

测试用的假读取器故意以 **3 字节**为一片服务 **4 字节**的块，
所以每个块都必然跨片到达——一个「假设每块一次拿到一个缓冲」的实现会在这里失败。

## 4. `wholeFileDigestMatches` 是可空的，而且这是刻意的

当某块缺失或损坏时，整文件摘要是在**不完整或错误的数据**上算出来的。
此时报告 `false` 会暗示做过一次实际上无法诚实进行的比较，所以类型是 `bool?`：

| 值 | 含义 |
| --- | --- |
| `true` | 每个字节都在，且整文件摘要与冻结清单一致 |
| `false` | 每个字节都在，但整文件摘要不一致（说明清单本身有问题） |
| `null` | **没有计算**——有块缺失或损坏 |

`isExportable` 要求 `wholeFileDigestMatches == true`，所以 `null` 与 `false` 一样阻断导出，
不存在「因为没算出 false 所以放行」的路径。

## 5. 损坏块被降级，而不是被信任

协议 §5 允许 `committedBytes` 下降，理由正是：**一个内容错误的 committed 块会被之后每一次恢复信任**。
所以字节与冻结清单不符的块在终检这里被退回 `missing`，而不是留给续传跳过。

`demoteDamagedChunks: false` 提供只读检查：UI 在写任何东西之前先显示
「正在检查已接收内容」，诊断视图也需要能只看不改。

## 6. 跨模块：两个组件各自独立地拒绝「假完成」

这是本次最值得保留的性质。终检降级坏块之后：

- `ChunkRepository.isFullyCommitted` 为假，`missingChunkIndices` 包含该块；
- `TransferRepository.recordSavedExport` **自己**检查 committed 块数，因此拒绝记录导出。

两者都不需要相信对方的说法——终检不必声称「导出会自己检查」，导出守卫也不必信任「终检已经查过」。
测试 `a damaged file is no longer fully committed, so export refuses it` 直接覆盖这个组合。

## 7. 本次发现的开放缺口（未修，已登记）

**`TransferRepository.recordSavedExport` 不要求先通过终检。**

「完成＝终检通过且导出结果已提交」目前只由**调用约定**保证，不由代码强制：
调用方可以先跳过终检直接调用 `recordSavedExport`，而它只检查 committed 块数。
当所有块都 committed 但整文件摘要不一致时（清单级不一致），块数检查会通过。

今天这不可利用——**转移引擎尚不存在，没有任何生产调用方**。
但导出批次（下一批）必须把这个缺口关掉，否则「假完成」只能靠纪律避免。
**已作为复核项登记入台账 §5**，并写入任务卡剩余项，不假装本次已解决。

## 8. 实际执行的检查

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 格式化 | `dart format lib test tooling` | 通过 |
| 静态分析 | `flutter analyze` | `No issues found!` |
| 全量测试 | `flutter test` | **302 passed** |
| 存储测试 | `flutter test test/core/storage` | **139 passed** |
| 链接检查 | `python tooling/checks/check_links.py --strict` | 无断链 |
| 机密检查 | `python tooling/checks/check_secrets.py` | 无凭证材料 |
| CI 工作流检查 | `python tooling/checks/check_ci_workflow.py` | 不变量成立 |

## 9. 未执行与限制

1. **暂存损坏是经端口注入的。** 损坏的**判定逻辑**是真的（字节确实与冻结清单不符），
   但字节来自 `StagedChunkReader` 的测试替身，**不是**磁盘上真实损坏的暂存文件。
   真实暂存损坏还需要暂存层落地与 B03/B04 真机验证。
2. **没有真实的暂存读取实现。** 本次只定义端口；平台侧的文件读取（SAF / 句柄 /
   security-scoped）完全未实现，属 T03-01/B03。
3. **没有接线。** 终检实现完整，但**没有任何调度代码在传到全部 committed 之后调用它**；
   `isExportable` 也还没有任何消费方。
4. **isolate 未处理。** 哈希是 CPU 密集的；本次实现是 async 且按块流式，
   但**调用方**必须在后台 isolate 中运行大文件的终检，否则会占用 UI isolate
   （`AGENTS.md` §2 规则 4）。后台 isolate 模型仍未冻结（`SYSTEM_ARCHITECTURE.md` §12）。
5. **并发未验证。** 未在多连接或「终检与写入并发」下测量；
   `markChunksMissing` 目前不接受 `lease_epoch`（一个 T04-01 的既有 API 形状）。
6. 全部结论来自 Windows 桌面测试；未在 Android/iOS 真机运行。

## 10. 需要人工重点复核的区域

- **`recordSavedExport` 与终检的关系**（见 §7）：导出批次必须让代码而不是约定来强制这条规则。
- **`markChunksMissing` 不受写入世代约束。** 终检会调用它，而协议 §8 要求写入世代仲裁。
  缓解理由：降级只会**减少**信任，两个并发恢复都降级同一批块不会产生假完成；
  但**仍需人工确认**这一推理在并发恢复下成立，还是要给降级加世代前置条件。
- **`_DigestSink` 依赖 `startChunkedConversion` 只在 `close()` 时投递一次摘要。**
  若 `crypto` 的实现改变（或它开始分片投递），`late value` 会抛
  `LateInitializationError` 而不是静默给出错误摘要——失败方式是响的，但依赖了库行为。
- **整文件摘要与分块摘要都取自冻结清单。** 若清单本身被篡改，
  终检会「一致地」通过；防篡改属于清单来源与 TLS 绑定，不是本组件职责。
