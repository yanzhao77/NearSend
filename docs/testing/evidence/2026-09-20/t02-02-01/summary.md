# T02-02 状态、错误码和版本协商 — 运行汇总

- 运行 ID：`t02-02-01`
- 任务：[T02-02 状态、错误码和版本协商](../../../../tasks/T02-02.md)
- 日期：2026-09-20
- 分支：`feat/t02-02-protocol-model`
- 基线：`master` @ `d55a77f028731f3f04ef86d17e86abf22ad0d887`
- 主机：Windows 10 22H2，Flutter 3.47.5 / Dart 3.13.4，Python 3.10.9

## 1. 交付内容

把协议草案中以散文描述的规则收敛为 Dart 中**可测试的唯一实现**：

| 文件 | 内容 |
| --- | --- |
| `protocol_exception.dart`（扩展） | §11 全部错误码 + HTTP 状态 + 可重试性 + 安全文案键；`ErrorScope`、`ProtocolError` |
| `protocol_version.dart` | `ProtocolVersion`、`Capability`、`CapabilitySet`、协商算法、冻结任务不可变判定 |
| `transfer_state.dart` | 任务状态机（16 状态，每条迁移标注 §10 依据）与文件状态机 |
| `retry_policy.dart` | §11 的超时常量、指数退避与抖动、Retry-After 上限、前台重试窗口 |
| `idempotency.dart` | `request_id` 作用域与幂等存储、`LeaseEpoch`/`LeaseGuard`、`ResumeCoordinator` |

## 2. 结果

| 检查 | 结果 |
| --- | --- |
| `dart format --set-exit-if-changed` | 通过 |
| `flutter analyze` | `No issues found!` |
| `flutter test`（全部） | **163 / 163 通过**（T02-01 时为 84） |
| `flutter test test/core/protocol` | **127 / 127 通过**（日志 `protocol-tests.log`） |
| `tooling/s0` 参考探针 | 24 / 24 通过 |
| 相对链接（`--strict`）/ 敏感信息 / CI 不变量 | 通过（179 链接、198 跟踪文件） |

## 3. 关键规则如何被固定

**错误模型**：§7 规定错误体含 `retryable`，因此「能否重试」是线上契约。测试逐码断言
HTTP 状态与可重试性，并且**只有** §11 明确要求「退避」的三种码（`RATE_LIMITED`、
`STORAGE_SYNC_FAILED`、`DB_COMMIT_FAILED`）为可重试。特别地，`SPACE_INSUFFICIENT` 是
**不可自动重试**的：§11 的行为是「用户清理/换位置后重试」，原样重发不可能成功。

**版本协商**：主版本不同直接拒绝；次版本差异在共有能力覆盖任务需求时继续。
`v1.0-draft1.md` 未规定次版本的取值规则，实现取**较低**的次版本并注明这是保守解读
（对端可能未实现较高次版本引入的能力），需在冻结时确认。

**状态机**：每条迁移带 `TransitionSource`（`stated` / `derived`），并在 rationale 中引用 §10。
测试断言「每条迁移都有依据」「stated 迁移必须引用 §10」，使表格无法悄悄扩张。

**幂等与世代**：`ResumeCoordinator` 把 §9 的顺序固定下来——同 ID 不同参数 → 冲突；
在途 → 202 语义；已完成 → 重放且**不再升代**；已有更高世代 → `STALE_RESUME_REQUEST`；
否则分配新世代。`LeaseGuard` 在每次写入时重新校验世代（§8 指出只在请求入口检查不够）。

## 4. 本任务发现的草案缺口（三项，全部登记而非自行补全）

这些不是实现细节，而是**冻结协议 v1 之前必须由维护者决定**的草案空缺。
每一项都以可执行断言固定，因此无法被静默遗忘。

### 4.1 能力词表未定义

§3 写作 `capabilities:[...]`，全篇没有任何能力标识；§17.1 要求「双方共有能力覆盖任务需求」，
但「任务需求」的能力集同样未定义。`AGENTS.md` §3 禁止凭偏好定案，因此本任务
**实现协商算法**（完全可测，测试使用合成标识）并且**不发明词表**。

### 4.2 `BLOCKED` / `FAILED` / `PARTIALLY_COMPLETED` 没有出边

§10 只说明如何**进入**这些状态：

- `failed` 与 `partiallyCompleted` **完全没有出边**，因此无法重试。这与
  V2.1 §16.1「只重试失败项」以及 §10 自身「部分完成可继续」的承诺直接冲突。
- `blocked` **唯一的出边是取消**。这与 §11 对 `SPACE_INSUFFICIENT` 的处方
  （「用户清理/换位置后重试」）冲突，而且取消会丢弃用户被承诺会保留的恢复数据。

测试 `statesWithoutDefinedExit` 与 `statesThatCanOnlyBeCancelled` 精确断言这两个集合。

### 4.3 文件级失败无法重试

`FileState.failed` 没有出边，文件状态机无法表达「只重试失败项」。
以 `FileStateMachine.retryOfFailedFilesIsDefined = false` 显式暴露并断言。

> 三项都属于「协议变更」，不能只靠改代码解决。它们不影响 T02-02 的退出门槛
> （模型与未知字段规则），但**必须在申请冻结协议 v1 之前解决**。

## 5. 过程中修复的问题

首次运行 `flutter analyze` 报 2 个错误：`ProtocolVersion` 只实现了 `compareTo` 与 `==`，
而测试使用了 `>`。补齐了四个比较运算符。这不是设计问题，但说明了「先写模型再写断言」
时接口完备性必须由编译器检查，而不是靠记忆。

## 6. 已知限制与未执行项

1. **协议未冻结。** 本任务把规则收敛为可测试模型，冻结需另行申请，且必须先解决 §4 的三项缺口。
2. **未实现 HTTP 服务器与路由**（T03-01）；本任务只有模型与纯函数。
3. **幂等记录与世代目前是内存实现。** 持久化必须与效果在同一事务提交（否则记录与效果会分叉），
   那是 T04-01 的职责；本文件有意不依赖 SQLite。
4. **能力词表的取值**未实现，见 §4.1。
5. 未做性能验证：状态表与集合运算规模很小，未测量；真机与网络行为属平台任务。
6. `tooling/s0` 在本机需要 Git 的 openssl 排在 anaconda 之前（环境问题，已在 T01-01 证据记录）；
   Linux CI runner 不受影响。
