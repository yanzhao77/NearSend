# T03-01 第十二批：清单页写入与 seal（§6 的生命周期） — 运行汇总

- 运行 ID：`t03-01-12`
- 任务：[T03-01 同网二维码配对与信任](../../../../tasks/T03-01.md)
- 日期：2026-09-20
- 分支：`feat/t03-01-manifest-seal`
- 基线：`master` @ `d4ac865`
- 主机：Windows 10 22H2，Flutter 3.47.5 / Dart 3.13.4

## 1. 本次实现的内容

| 文件 | 内容 |
| --- | --- |
| `lib/core/protocol/transfer_seal_request.dart` | `POST /transfers/{id}/seal` 请求体（新增） |
| `lib/core/network/manifest_staging_registry.dart` | 按 `transferId` 找 staging，并**执行 §6 的 30 分钟窗口**（新增） |
| `lib/core/network/transfer_staging_endpoint.dart` | `PUT /transfers/{id}/manifest` 与 `POST /transfers/{id}/seal`（新增） |
| `lib/core/network/control_authorization.dart` | `credentialFingerprintOf`：§9 作用域的**单一定义**（两个端点共用） |
| `lib/core/network/transfer_creation_handler.dart` | 改用共用助手，删掉自己的私有副本 |
| 测试 | seal 请求体 10 项 + staging 注册表 10 项 + 两个端点 20 项 |

测试规模：Flutter **957 → 997**。

## 2. 本批几乎没有新的协议逻辑，这是有意的

`ManifestPage` 已经校验页的形状与 §5.1 的路径/大小上限；`ManifestStaging` 已经
**按索引存储**（所以重复页不会增加计数）、拒绝**内容不一致的重叠区间**，并按 §6 的顺序 seal、
把**总摘要放在最后**。这些都有各自的测试（`t03-01-05`，528 行）。

所以本批加的是**只有端点才能负责**的部分：按路径里的 transfer 找到正确的 staging、
执行 §6 的撤销窗口、把 seal 变成**持久的状态变更**——并在 manifest 无法 seal 时**不移动任务**。
**没有把已有的 staging 测试抄一遍**：那会让测试文件更长而不增加证据。

## 3. §6 的 30 分钟窗口终于有了执行者

§6：「首次收到内容后 30 分钟 staging 未完成则清理并撤销该提议；**不影响已经冻结的任务**」。

`ManifestStaging.isExpired` 此前**只是一个谓词，没有任何代码调用它**（台账登记的剩余项）。
本批在使用点执行它：对已过期提议的页或 seal 答 **410 `TASK_EXPIRED`**，并**丢弃该提议**；
而**一旦 manifest 被冻结，窗口就不再适用**——这正是那句话强调的后半句。
测试对两半都做了断言：

- 超过窗口 → `TASK_EXPIRED`，且 `stagedTransferCount` 归零；
- **已 seal 的 manifest 在窗口过后仍然可用**，`sealedTransferCount == 1`。

另有一条测试固定「窗口从**首次内容**起算」：从未上传过任何页的传输**不会**因为创建得久而过期
（`firstContentAtMillis` 为 null）。

## 4. 两个绑定在 §6 上的规则

**重传是成功，不是错误。** §6「重传相同页返回成功」。丢了响应的客户端**无法分辨**
「第一次到了」与「第二次到了」，所以 `stored` 与 `alreadyStored` 都答 `200 {stored:true}`。
把后者答成错误会让一次响应丢失变得**不可恢复**——正是 §6 想避免的。

**seal 的两种幂等。** §9 让重复的 `requestId` **重放**已存结果；
而 `ManifestStaging.seal` 本身在第二次调用时**返回同一个冻结清单**。
后者是必需的，因为 seal 的效果**一部分在内存里**：如果数据库事务在 manifest 冻结之后失败，
重试必须仍然能完成，而不是发现一个再也 seal 不了的 manifest。
一条测试用「同一 requestId 重试仍然 200 且任务仍是 WAITING_ACCEPT」固定了这一点——
若没有重放，第二次状态迁移会被状态机拒绝，测试就会失败。

## 5. 一处判断：摘要检查放在 idempotency **内部**

§7 把 seal 配以「**摘要失败 422**」，而 body 里的摘要是**客户端的声称**，
transfer 创建时声明的那个才是**权威**。第一版把这项检查放在 `executeAtomically` **之前**，
于是「同一个 `requestId` 换一个摘要」会被答成 `MANIFEST_MISMATCH`——
但 §9 说那正是 **`REQUEST_ID_CONFLICT`**（同 ID 不同参数）。

改成放在**效果的内部**后三种情形各得其所：

| 情形 | 答复 |
| --- | --- |
| 新 `requestId` + 摘要与声明不符 | **422 `MANIFEST_MISMATCH`** |
| 同 `requestId` + 摘要不同 | **409 `REQUEST_ID_CONFLICT`** |
| 同 `requestId` + 摘要相同 | **200，重放** |

**这个缺陷是写测试时自己发现的**：测试名与断言不一致，追下去发现是检查顺序错了。

## 6. 未移动任务这件事被单独验证

§6：「缺页、重复 fileId、块数量/长度错误、总摘要不一致时 seal 失败，**不能进入 WAITING_ACCEPT**」。
所以每条失败路径的测试都**额外断言 `taskState` 仍是 `staging`**，而不只是断言抛出的错误码。
空清单、缺块页、摘要不符、body 畸形四条路径都如此。
一条测试还固定了「`seal` 之后的页写入被答 `INVALID_STATE`」（§6「seal 后页不可修改」）。

## 7. 存储层的状态名与线上名不同（复核要点）

测试第一次运行时全部报 `has unknown state "STAGING"`。原因是
`tasks.state` 存的是 **Dart 枚举名**（`staging`，小写），而线上是 **`wireName`**（`STAGING`）。
`_parseTransferState` **拒绝**未识别的值（这是对的），所以测试里写成线上名就立刻失败了。

这**不是缺陷**——两套名字各有用途（`core/protocol` 面向线上，`core/storage` 面向库）——
但它是一个**容易踩的坑**，且只在有人手写状态字符串时才会暴露。已登记为复核项。

## 8. 实际执行的检查

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 格式化 | `dart format --output=none --set-exit-if-changed lib test tooling` | 通过（0 changed） |
| 静态分析 | `flutter analyze`（**未过滤输出**） | `No issues found!` |
| 全量测试 | `flutter test` | **997 passed**（957→997） |
| 端点测试 | `flutter test test/core/network/transfer_staging_endpoint_test.dart` | 20 passed |
| 注册表测试 | `flutter test test/core/network/manifest_staging_registry_test.dart` | 10 passed |
| 链接检查 | `python tooling/checks/check_links.py --strict` | 58 文件 / 337 链接，无断链 |
| 机密检查 | `python tooling/checks/check_secrets.py` | 305 个跟踪文件，无凭证材料 |
| CI 工作流检查 | `python tooling/checks/check_ci_workflow.py` | 不变量成立 |

## 9. 未执行与限制

1. **staging 是进程内的**：不落 SQLite。这是对 §6 的**读法**而非疏漏——
   协议没要求 staging 跨重启保留，而重启的代价是客户端重传，§6 让重传安全
   （「重传相同页返回成功」，且按索引存储使重复页无法虚增计数）。
   **代价必须说清楚**：**重启后此前 seal 的清单就没了**，因此 chunk 端点会要求客户端重传并重新 seal。
   本 build **不得声称传输能跨服务端重启存活**。
2. **仍未接收块**：`PUT/GET .../chunks/{index}` 未实现，所以 `WAITING_ACCEPT` 之后没有下一步。
   `decision`（接收方批准）也未实现。
3. **§6 的「重复 fileId」与「块数量/长度错误」两条 seal 前置条件**由 `ManifestStaging` 覆盖
   （`t03-01-05` 的测试），本批**没有重复测试**它们，端到端只覆盖了「缺页」与「摘要不符」。
4. **`decision` 之后的空间检查未接线**（§6「批准清单摘要、保存位置以及空间估算一起持久化」）。
5. **会话说不上任务**：`createTransfer` 要**会话身份**，而 `putManifest`/`seal` 要**该 transfer 的任务令牌**，
   所以完整生命周期需要两个凭证（测试就是这样做的）。**会话到任务的映射仍未建模**，
   会话身份在任务作用域路由上仍被保守拒绝（沿用 `t03-01-11` 的登记）。
6. **没有 HTTP 服务器与 TLS**；端点经管线调用。
7. **19 行里其余 16 行仍答 404**。正确描述是「**3 个端点可用（create、清单页、seal），其余 16 个未实现**」。
8. **未在 Android/iOS 真机运行**。

## 10. 需要人工重点复核的区域

- **`isExpired` 的执行语义**（§3）：窗口只在**未冻结**时适用，且拒绝时**丢弃**提议。
  若协议意图是「冻结后也按保留期清理」，则本层少做了一步——但那属于保留期而非 staging 窗口。
- **seal 效果的「一半在内存」**（§4）：`seal()` 的冻结**不会**被数据库回滚撤销。
  本层靠 `seal()` 的幂等性让重试仍然可行。复核要点是：**任何未来的 seal 前置校验都必须保持幂等**，
  否则「DB 失败后重试」会永久卡住。
- **摘要检查的位置**（§5）：放在效果内部是为了让 §9 先看到请求。若将来有人为了「更早失败」把它移出去，
  `REQUEST_ID_CONFLICT` 就会变成 `MANIFEST_MISMATCH`，而两个码的处方不同。
- **存储状态名 vs 线上名**（§7）：`tasks.state` 存 Dart 枚举名，线上是 `wireName`。
  手写状态字符串的地方会踩这个坑；复核时应确认没有新的手写点。
- **`ManifestStagingRegistry` 的内存增长**：按 transfer 累积，只在过期、丢弃或 seal 后保留。
  一个 seal 过的传输会**永久**占用内存直到进程结束。§5 允许单传输 10,000 文件，
  多传输并发时这是真实的内存风险，**需决定保留策略**。
