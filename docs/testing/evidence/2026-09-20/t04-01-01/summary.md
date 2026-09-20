# T04-01 SQLite 绑定验证与范围定案 — 运行汇总

- 运行 ID：`t04-01-01`
- 任务：[T04-01 SQLite schema、迁移框架与 chunk repository](../../../../tasks/T04-01.md)
- 日期：2026-09-20
- 分支：`feat/t04-01-sqlite-repository`
- 基线：`master` @ `c38a5e17647c51a08c5f8e6760d01a7a0b989cc1`
- 主机：Windows 10 22H2，Flutter 3.47.5 / Dart 3.13.4

## 这一轮做了什么、没做什么

台账中 T04-01 的状态是「待澄清」——范围没有冻结。按 `AGENT_TASK_PLAYBOOK.md`
「没有清晰退出门槛时先补卡，不直接编码」，并且按 `SYSTEM_ARCHITECTURE.md` §12
「SQLite 插件…尚待冻结」，本轮完成两件**必须先做**的事：

1. 把范围定案写入任务卡（范围内/范围外/接口不变量/验收条件/故障矩阵）；
2. 完成 SQLite 绑定这一**依赖决策的实际验证**，见 [ADR-0003](../../../../decisions/ADR-0003-SQLite绑定与耐久性配置.md)。

**schema、迁移、repository 与故障注入测试尚未实现**，将在本任务的后续提交中完成。
本文件不把「绑定可用」当作「存储层已完成」。

## 绑定验证结果

`test/core/storage/sqlite_binding_probe_test.dart` 在本机 **5/5 通过**，无需额外原生库配置
（`sqlite3` 3.x 通过 Dart build hook 提供原生库）：

| 验证项 | 结果 |
| --- | --- |
| 绑定加载并报告版本 | 通过；运行时库 **SQLite 3.53.4**（包 `sqlite3` 3.6.0） |
| `PRAGMA journal_mode = WAL` | 接受 |
| `PRAGMA synchronous = FULL` | 读回 **2**，即 FULL |
| `PRAGMA foreign_keys = ON` | 读回 **1** |
| 提交的事务在关闭并重新打开文件后仍存在 | 通过 |
| 回滚的事务不留下任何内容 | 通过 |
| 事务内语句失败不使连接失效 | 通过 |

`synchronous=FULL` 读回为 2 这一点是刻意验证的：协议 §8 的提交顺序依赖
「durable sync 之后才提交」，如果该设置被静默降级，崩溃后就会出现「已确认但未落盘」的块——
而这正是本项目最不能接受的失败模式。

「事务内语句失败不使连接失效」同样刻意：否则一次可恢复的块错误会升级为整个任务失败。

原始日志：`sqlite-binding-probe.log`。

## 发现的一个真实维护状态问题

按旧有习惯会顺手添加 `sqlite3_flutter_libs`。实际解析到的版本是 **`0.6.0+eol`**，
其 CHANGELOG 明确写着：自 `0.6.0` 起该包**不再包含任何代码**，因为 `sqlite3` 3.x 已改用
build hooks 提供原生库；README 也标注它为 obsolete。

也就是说，加了它只会得到一个「什么都不做」的依赖，而且会在升级文档之外多留一个误导项。
已**移除**，并把这件事记入 ADR-0003 的候选评估表。
这正是 `APP_AND_SERVICE_DESIGN.md` §12 要求核对「维护状态」的原因。

## 未执行与限制

1. **schema/迁移/repository/故障注入未实现**。任务卡已冻结范围，实现是后续提交。
2. **平台 `syncData` 的真实语义未验证**。探针只证明 PRAGMA 被接受与事务原子性，
   **没有**证明真机存储后端在断电时兑现 `synchronous=FULL`。该结论属 B04 真机故障注入，
   在获得证据前不得声称写入耐久性已验证。
3. 未做 Android/Windows 真机运行验证；本机是 Windows 桌面测试环境。
4. 未决定后台 isolate 的线程模型（`SYSTEM_ARCHITECTURE.md` §12 仍未冻结）。
5. `flutter analyze` 首次运行报 6 处 `dispose` 弃用提示，已改为 `close()`。
