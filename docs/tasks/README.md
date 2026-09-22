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
| [T03-01](T03-01.md) | 同网二维码配对与信任 | 进行中（目标端网络绑定阻塞于 B02） | 12 批实现及合并记录：[PR #29–#51](https://github.com/yanzhao77/NearSend/pulls?q=is%3Apr+is%3Amerged+29..51)；最新 [#51](https://github.com/yanzhao77/NearSend/pull/51) |
| [T04-01](T04-01.md) | SQLite schema、迁移框架与 chunk repository | 进行中 | `feat/t04-01-*` → [#13](https://github.com/yanzhao77/NearSend/pull/13)、[#15](https://github.com/yanzhao77/NearSend/pull/15)、[#17](https://github.com/yanzhao77/NearSend/pull/17)、[#19](https://github.com/yanzhao77/NearSend/pull/19) |
| [T06-01](T06-01.md) | 空间计划、终检与导出 | 进行中 | `feat/t06-01-*` → [#21](https://github.com/yanzhao77/NearSend/pull/21)、[#23](https://github.com/yanzhao77/NearSend/pull/23)、[#25](https://github.com/yanzhao77/NearSend/pull/25)、[#27](https://github.com/yanzhao77/NearSend/pull/27) |
| [T03-02](T03-02.md) | Android→Windows 局域网端到端单文件闭环 | 进行中 | `feat/t03-02-lan-e2e` → [#56](https://github.com/yanzhao77/NearSend/pull/56) |
| [T11-01](T11-01.md) | MVP 双向数据面（Android ↔ Windows） | 进行中（UI 与真机端到端未完成） | `feat/mvp-bidirectional-transfer` |
| [T11-02](T11-02.md) | UI 装配：节点生命周期与「发送」接通会话 | 进行中（节点生命周期、真实 pin 上屏与配对已交付；选择→会话→进度、接收侧与真机第 6 项未完成） | `feat/mvp-bidirectional-transfer` |
| [T12-00](T12-00.md) | UI 平台能力 S0 与任务基线 | 已完成：探针记录；平台能力未全部验证 | `feat/ui-baseline` |
| [T12-01](T12-01.md) | 主题与 Design Token | 就绪 | `feat/ui-baseline` |
| [T12-02](T12-02.md) | 共享 UI 组件 | 就绪 | `feat/ui-baseline` |
| [T12-03](T12-03.md) | 响应式应用壳与真实数据读模型 | 待验证 | `feat/ui-baseline` |
| [T12-04](T12-04.md) | 首页与关于页 | 待验证 | `feat/ui-baseline` |
| [T12-05](T12-05.md) | 配对与连接页 | 待验证 | `feat/ui-baseline` |
| [T12-06](T12-06.md) | 发送流程页面 | 就绪 | `feat/ui-baseline` |
| [T12-07](T12-07.md) | 接收流程与空间预检 | 就绪 | `feat/ui-baseline` |
| [T12-08](T12-08.md) | 任务详情、传输详情与结果 | 就绪 | `feat/ui-baseline` |
| [T12-09](T12-09.md) | Android、Windows、iOS 平台适配 | 就绪 | `feat/ui-baseline` |
| [T12-10](T12-10.md) | UI 最终验收与证据 | 就绪 | `feat/ui-baseline` |
| T10 | 安装升级与发布 | 进行中（GitHub Actions 自动发版已完成；签名、升级和正式分发待完成） | [发布说明](../releases/GITHUB_ACTION_RELEASES.md) |

各任务的完成依据见对应运行汇总：T01-01 [证据](../testing/evidence/2026-09-20/t01-01-01/summary.md)、
T01-02 [证据](../testing/evidence/2026-09-20/t01-02-01/summary.md)、
T02-01 [证据](../testing/evidence/2026-09-20/t02-01-01/summary.md)、
T02-02 [证据](../testing/evidence/2026-09-20/t02-02-01/summary.md)、
T03-01 [证据](../testing/evidence/2026-09-20/t03-01-01/summary.md)、
T04-01 [证据](../testing/evidence/2026-09-20/t04-01-05/summary.md)、
T06-01 [证据](../testing/evidence/2026-09-20/t06-01-04/summary.md)。

**已完成仅表示该任务自身的退出门槛全部满足**，不表示任何传输、配对、存储或恢复能力已经实现；
平台能力结论仍需目标设备证据。本表的状态必须与 [项目台账](../PROJECT_LEDGER.md) 一致。

后续任务卡在依赖满足后再新建，不预先生成空卡。

T10 当前以发布说明和项目台账作为事实源，暂不创建没有独立退出门槛的空任务卡。
