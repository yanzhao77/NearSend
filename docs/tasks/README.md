# NearSend 任务卡索引

本目录是 NearSend 开发任务卡的**唯一存放位置**。

## 为什么放在 Git 而不是 Issue

`docs/AGENT_TASK_PLAYBOOK.md` §3 要求任务卡「直接提交到 GitHub Issue 或 `docs/tasks/`（二选一后保持统一）」。
本项目选择 `docs/tasks/`，依据：

- `AGENTS.md` 核心规则 12：关键决定必须进入 Git，不能只保存在聊天记录或外部系统中；
- 任务卡的退出门槛、依赖和证据链接需要与协议、schema、台账在同一版本历史中一起演进；
- 评审时可以把「任务卡 → 分支 → 证据 → 台账」放在同一个 diff 里审阅。

PR 仍然按 `docs/DEVELOPMENT_WORKFLOW.md` §6 的要求创建，并在描述中引用任务卡路径与任务 ID。

## 命名与模板

- 文件名：`<任务ID>.md`，与 `docs/PROJECT_LEDGER.md` 中的任务 ID 完全一致，例如 `T01-01.md`。
- 内容：严格使用 `docs/AGENT_TASK_PLAYBOOK.md` §2 的标准任务卡模板。
- 一个任务卡只覆盖一个可验证边界，不合并多个里程碑。

## 状态口径

任务卡中的状态必须与 `docs/PROJECT_LEDGER.md` 一致，取值只能是：

`待澄清` / `就绪` / `进行中` / `待验证` / `阻塞` / `已完成` / `已取消`

「代码已写完」通常只能进入 `待验证`。只有退出门槛全部满足、必要证据存在并且已合并，才允许改为 `已完成`。

## 任务卡列表

| 任务 ID | 标题 | 状态 | 分支 / PR |
| --- | --- | --- | --- |
| [T01-01](T01-01.md) | Flutter 工程基线 | 已完成 | `feat/t01-01-flutter-baseline` → [#4](https://github.com/yanzhao77/NearSend/pull/4)、[#5](https://github.com/yanzhao77/NearSend/pull/5) |
| [T01-02](T01-02.md) | CI 与检查 | 已完成 | `feat/t01-02-ci-checks` → [#6](https://github.com/yanzhao77/NearSend/pull/6)、[#7](https://github.com/yanzhao77/NearSend/pull/7) |
| [T02-01](T02-01.md) | Dart canonical manifest | 已完成 | `feat/t02-01-canonical-manifest` → [#8](https://github.com/yanzhao77/NearSend/pull/8)、[#9](https://github.com/yanzhao77/NearSend/pull/9) |
| [T02-02](T02-02.md) | 状态、错误码和版本协商 | 已完成 | `feat/t02-02-protocol-model` → [#10](https://github.com/yanzhao77/NearSend/pull/10)、[#11](https://github.com/yanzhao77/NearSend/pull/11) |
| [T04-01](T04-01.md) | SQLite schema、迁移框架与 chunk repository | 进行中 | `feat/t04-01-*` → [#13](https://github.com/yanzhao77/NearSend/pull/13)、[#15](https://github.com/yanzhao77/NearSend/pull/15)、[#17](https://github.com/yanzhao77/NearSend/pull/17)、[#19](https://github.com/yanzhao77/NearSend/pull/19) |
| [T06-01](T06-01.md) | 空间计划、终检与导出 | 进行中 | `feat/t06-01-space-planning` |

各任务的完成依据见对应运行汇总：T01-01 [证据](../testing/evidence/2026-09-20/t01-01-01/summary.md)、
T01-02 [证据](../testing/evidence/2026-09-20/t01-02-01/summary.md)、
T02-01 [证据](../testing/evidence/2026-09-20/t02-01-01/summary.md)、
T02-02 [证据](../testing/evidence/2026-09-20/t02-02-01/summary.md)、
T04-01 [证据](../testing/evidence/2026-09-20/t04-01-05/summary.md)。

**已完成仅表示该任务自身的退出门槛全部满足**，不表示任何传输、配对、存储或恢复能力已经实现；
平台能力结论仍需目标设备证据。本表的状态必须与 [项目台账](../PROJECT_LEDGER.md) 一致。

后续任务卡在依赖满足后再新建，不预先生成空卡。
