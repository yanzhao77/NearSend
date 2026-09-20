# ADR-0003 SQLite 绑定与耐久性配置

- 状态：已接受（绑定）；耐久性配置部分待真机验证
- 日期：2026-09-20
- 任务：T04-01
- 依据：`docs/architecture/SYSTEM_ARCHITECTURE.md` §12、`docs/architecture/APP_AND_SERVICE_DESIGN.md` §10/§12、`AGENTS.md` §3/§5、协议 §8

## 背景

`SYSTEM_ARCHITECTURE.md` §12 把「SQLite 插件、后台 isolate 与平台 durable sync 行为」列为
**尚待冻结**的选择；`AGENTS.md` §3 禁止凭偏好定案，要求先记录候选、验证结果与决策依据。

接收方 SQLite 中的 committed 块是断点续传的唯一权威（`AGENTS.md` §2 规则 5），
而块提交顺序是 `写入 → 分块哈希校验 → durable sync → SQLite 事务提交 → 向发送端确认`（协议 §8）。
这意味着绑定必须允许**显式控制事务边界与 PRAGMA**，不能把耐久性语义藏在插件的默认值里。

## 候选与验证

| 候选 | 评估 |
| --- | --- |
| `sqlite3`（FFI，simolus3） | **选用**。直接用 `dart:ffi` 绑定，可执行任意 PRAGMA 与显式事务；跨 android/ios/windows/linux/macos |
| `sqflite` + `sqflite_common_ffi` | 否决。Flutter 惯用但对 PRAGMA、事务边界与打开方式的控制更间接，且桌面需要额外 FFI 初始化；本项目需要能逐条断言耐久性设置 |
| `drift` | 否决。在其上再包一层 ORM，增加依赖面与代码生成；当前 schema 很小，收益不足 |
| 自建 FFI 绑定 | 否决。等于自制数据库绑定，收益为零且维护成本高 |
| `sqlite3_flutter_libs` | **否决并已移除**。该包自 `0.6.0` 起**已废弃且不再包含任何代码**（`+eol`），因为 `sqlite3` 3.x 改用 Dart build hooks 提供原生库。**这是本任务实际查到的维护状态问题**——若按旧文档习惯添加它，会得到一个什么都不做的依赖 |

## 本机验证结果（`docs/testing/evidence/2026-09-20/t04-01-01/`）

`test/core/storage/sqlite_binding_probe_test.dart` 在 Windows 10 22H2 上 **5/5 通过**，
**无需任何额外的原生库配置**（`sqlite3` 3.x 的 build hook 提供）：

| 验证项 | 结果 |
| --- | --- |
| 绑定加载并报告版本 | 通过，运行时库 **SQLite 3.53.4**（包版本 3.6.0） |
| `PRAGMA journal_mode = WAL` 被接受 | 通过 |
| `PRAGMA synchronous = FULL` 读回为 2 | 通过——这是「durable sync 后提交」依赖的设置，若被静默降级会导致崩溃后确认未落盘的块 |
| `PRAGMA foreign_keys = ON` 读回为 1 | 通过 |
| 提交的事务在关闭并重新打开文件后仍存在 | 通过 |
| 回滚的事务不留下任何内容 | 通过 |
| 事务内某条语句失败不会使连接失效 | 通过——否则一次可恢复的块错误会升级为任务失败 |

这个探针保留为**常驻测试**而不是一次性 spike：它守护的失败模式（应用包内可用但 `flutter test` 下不可用、
或 WAL/同步设置被静默忽略）若只在检查点协议建好之后才发现，代价会高得多。

## 决策

1. 使用 `sqlite3`（`^3.6.0`，MIT，Simon Binder）作为唯一 SQLite 绑定。
2. **不**引入 `sqlite3_flutter_libs`（已废弃且为空包）。
3. 打开数据库时显式设置：`journal_mode = WAL`、`synchronous = FULL`、`foreign_keys = ON`；
   这些是本项目的耐久性契约，不由插件默认值决定。
4. `syncData` 的**实际平台语义仍未验证**：探针只证明了 PRAGMA 被接受与事务原子性，
   没有证明真机存储后端在断电时会兑现 `synchronous=FULL`。这属于 B04 的真机故障注入范围，
   在获得该证据前，不得声称写入耐久性已经验证。

### §12 要求的其余评估项

| 项目 | 内容 |
| --- | --- |
| 用途 | 接收方的任务/文件/块/幂等/导出持久化；committed 块的唯一权威 |
| 维护状态 | 活跃维护（simolus3/sqlite3.dart），3.x 为当前主版本并有明确升级说明 |
| 许可证 | MIT |
| 支持平台 | android / ios / windows / linux / macos（本项目只需要前三者） |
| 是否接触文件、网络或密钥 | 接触**文件**（按要求打开指定路径的数据库文件）。不访问网络；**不持有密钥**——恢复凭证属于平台安全存储（`AGENTS.md` §5），不得写入普通 SQLite 字段 |
| 二进制体积 | 原生 SQLite 由 build hook 编入，Android 与 Windows 上可接受；发布包体积属 T10 的检查项 |
| 已知安全问题 | 无未修复的已知问题；SQLite 本体随包升级 |

## 影响与未决

- `pubspec.lock` 已更新，CI 的依赖锁文件检查覆盖本次变更。
- **后台 isolate 与平台 durable sync 行为仍未冻结**：何时把哈希与磁盘操作移出 UI isolate，
  以及各平台 `syncData` 的真实语义，需要真机验证（B04）后再定。
- 高版本 schema 拒绝写入、迁移失败回滚等策略在 T04-01 的任务卡中定义，
  其真机验证同样归入 B04。
