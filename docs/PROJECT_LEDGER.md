# NearSend 项目现状与进度台账

更新日期：2026-09-20。范围：技术方案V2.1、协议草案、S0参考实验、研发治理与实施规格。后续以本文件最新Git版本为准，不用聊天记录代替状态。

## 一句话现状

**S0进行中：产品方向、实施架构、端侧分层、UI/UX、质量门禁和 Agent 工作流已形成设计基线；协议草案与 Python 参考实验已完成；T01-01 已建立 Android/Windows/iOS 三端 Flutter 工程与版本可追踪的壳应用，并在 Android 真机与 Windows 上构建运行通过；T01-02 已把必做检查与双端构建固化为 GitHub Actions 门禁并在真实运行中全部通过。传输、配对、发现、存储与恢复功能均未实现；没有可分发安装包或正式发布版本；协议与关键平台选型尚未冻结。**

## 1. 状态口径

- 已完成：限定范围内已有文件及可核对证据，不自动等于产品功能完成。
- 部分完成：某一参考层通过，仍有明确退出门槛。
- 阻塞：缺必要环境/设备，未执行，不计为通过或失败。
- 待开始：尚无该产品模块实现。
- 待复核：需要人工或独立实现验证，不用同一参考代码的自测替代。

不计算没有依据的整体完成百分比，不将Linux实验或HTTP loopback称为跨平台验收。

## 2. 成果台账

| ID | 成果 | 状态 | 证据/位置 | 限制及下一步 |
| --- | --- | --- | --- | --- |
| D01 | 定位与技术方案V2.1 | 已完成：设计 | [方案](跨平台离线文件互传系统技术方案_V2.1.md) | 保留现有产品摘要和发布策略；不是实现证明 |
| D02 | AI开发规则 | 已完成：规则 | [AGENTS.md](../AGENTS.md) | 本次未改动 |
| D03 | 协议v1.0-draft1 | 已完成：草案；未冻结 | [协议](protocol/v1.0-draft1.md) | 待独立实现、接口鉴权及平台验证 |
| D04 | 固定编码/摘要向量 | 部分完成：已有 Dart 独立比对 | [向量](protocol/vectors-v1.json)、[Dart 实现](../lib/core/protocol/manifest.dart)、[T02-01 证据](testing/evidence/2026-09-20/t02-01-01/summary.md) | 三个向量的 LFTM1/LFTC1 字节与摘要已被 Dart 独立复现一致；仍待 Kotlin/Swift/Windows 独立实现比对 |
| E01 | 24项自动化实验 | 已完成：Linux参考层 | [原日志](testing/evidence/2026-09-20/unit-tests.log)、[导入复测](testing/evidence/2026-09-20/repository-import-tests.log) | 不覆盖完整产品API和设备生命周期 |
| E02 | TLS1.3与pin正反例 | 已完成：本机loopback | 同E01、[探针](../tooling/s0/test_probes.py) | 待三端引擎及网络绑定验证 |
| E03 | 崩溃窗口与损坏块修复 | 已完成：本地参考层 | 同E01、[存储探针](../tooling/s0/storage_probe.py) | 子进程退出；非断电、非平台生产存储 |
| E04 | 1GiB及20GiB真实落盘回读 | 已完成：Linux合成数据 | [1GiB](testing/evidence/2026-09-20/large-1gib.json)、[20GiB](testing/evidence/2026-09-20/large-20gib.json) | 无网络/任务DB/导出；本次导入未重跑 |
| E05 | 1,000/10,000小文件及100空文件 | 已完成：本地存储层 | [结果](testing/evidence/2026-09-20/small-files.json) | 不包含UI、网络、混合队列；本次导入未重跑 |
| D05 | 真机执行单与限制 | 已完成：执行方案 | [S0报告](testing/S0-report.md) | 执行单不是执行结果 |
| D06 | 文档中心与权威关系 | 已完成：设计 | [文档中心](README.md) | 作为文档入口，不代表功能实现 |
| D07 | Vibe Coding 开发流程 | 已完成：治理 | [流程](DEVELOPMENT_WORKFLOW.md) | 后续任务须形成需求—PR—证据—台账闭环 |
| D08 | 系统架构 | 已完成：实施草案 | [架构](architecture/SYSTEM_ARCHITECTURE.md) | 平台依赖与部分接口待 S0 冻结 |
| D09 | 应用与端侧服务设计 | 已完成：实施草案 | [端侧设计](architecture/APP_AND_SERVICE_DESIGN.md) | NearSend 无中心云后台；具体库待验证 |
| D10 | UI/UX 与视觉基线 | 已完成：视觉设计 | [设计入口](ui/README.md)、[样式指南](ui/STYLE_GUIDE.md) | 已提供组件、移动端和 Windows SVG 视觉稿；待 Flutter 实现与可访问性验证 |
| D11 | 质量与验收策略 | 已完成：设计 | [质量策略](testing/QUALITY_AND_ACCEPTANCE.md) | 设备阈值待目标端基线形成后冻结 |
| D12 | Agent 任务手册 | 已完成：治理 | [任务手册](AGENT_TASK_PLAYBOOK.md) | 任务卡统一放在 [docs/tasks/](tasks/README.md)，见 ADR-0001 |
| R01 | Flutter客户端与原生适配 | 部分完成：工程基线 | [T01-01](tasks/T01-01.md)、[T01-01 证据](testing/evidence/2026-09-20/t01-01-01/summary.md) | Android/Windows/iOS 工程可构建；Android 真机与 Windows 均启动同一版本壳应用；传输、配对、发现、存储、恢复未实现 |
| R02 | 安装包、签名构建及发布CI | 待开始 | 无产物 | 当前只有发布策略，未发布任何版本 |
| R03 | CI 门禁与工具链固定 | 已完成 | [T01-02](tasks/T01-02.md)、[运行汇总](testing/evidence/2026-09-20/t01-02-01/summary.md) | 四个作业在 GitHub Actions 真实通过；签名与发布作业仍属 T10 |

历史实验环境见[environment.json](testing/evidence/2026-09-20/environment.json)。20GiB整文件哈希通过；峰值RSS为18,944KiB，1GiB为18,816KiB。该口径不包含系统页缓存，不代表真机吞吐量或完整应用内存。

## 3. S0门槛与阻塞台账

| ID | 优先级 | 项目 | 当前状态/阻塞 | 下一动作 | 完成标准 |
| --- | --- | --- | --- | --- | --- |
| B01 | P0 | Android热点与Windows加入 | 环境已具备（T01-01 安装 Flutter/Android SDK 并接入真机 25102RKBEC / Android 17）；探针未执行。限制：Windows 侧只有本机 Win10 + Intel AC-7265，且无第二台 Android 设备 | 准备原生探针，关闭上游网络测试 | 实际双向样本传输、重建热点重新认证 |
| B02 | P0 | Android指定Network与TLS衔接 | 真机与 SDK 已具备；纯Dart路径仍未确认 | 对比原生与Dart适配路径 | 多网络下走正确接口，pin前不发凭证 |
| B03 | P0 | URI重开、seek、权限与暂存 | 真机已具备；尚无真实文档提供者样本 | 本地/外接/云占位文件分别测试 | 重启重开或明确暂存/阻断路径 |
| B04 | P0 | 真实存储checkpoint及恢复 | 仍仅Linux参考层通过；真机存储后端未执行 | 真机存储后端执行故障窗口 | 不假提交，恢复最终哈希一致 |
| B05 | P0 | 协议跨语言与完整API | 只有Python子集 | 实现独立编码器及认证/分页/恢复接口 | 向量一致，授权与幂等正反例通过 |
| B06 | P1 | iOS关键能力探针 | 缺macOS/Xcode/iPhone | 早期验证TLS、局域网权限、文件生命周期 | 前后台中断后可靠恢复，记录实际边界 |
| B07 | P1 | 真机大文件与队列 | 尚无完整产品链路 | 先小样本，再20GiB及小文件集合 | 准备/传输/终检/导出全流程证据 |
| B08 | P2 | Windows自动离线组网 | 缺Windows环境/网卡矩阵 | 独立实验条件能力 | 按设备列支持范围，不阻塞Android热点主路径 |

责任分工：目标设备与开发环境由维护者提供或指定；探针实现、测试执行与证据更新由后续开发任务承担。当前未给任何具体人员分派GitHub任务，也没有未确认的截止日期。

## 4. 开发任务台账

| 任务 | 当前状态 | 退出门槛 |
| --- | --- | --- |
| T00 文档与研发治理 | 已完成：设计 | 文档索引、流程、架构、端侧、UI、质量和 Agent 手册已提交；后续持续维护 |
| T01 工程/构建/配置 | 已完成 | 两端可安装/运行、版本可追踪（§6.1）；检查与双端构建已固化为 CI 门禁（§6.2） |
| T02 协议/模型/向量 | 部分完成：模型已收敛，但**发现三处草案缺口** | 草案、Python 向量与 Dart 独立实现逐字节一致（T02-01）；错误码/状态机/协议协商/幂等已实现（T02-02）；**冻结被 §5 登记的三项草案缺口阻塞**，另需原生实现比对 |
| T03 配对与单文件链路 | 待开始：仅TLS探针 | 用户授权后端到端收发、鉴权负例通过 |
| T04 分块与checkpoint | 部分完成：实验 | 生产存储实现、批量窗口及背压验证 |
| T05 暂停/故障/重启恢复 | 部分完成：实验 | 双端真实进程/设备生命周期恢复 |
| T06 终检/导出/空间检查 | 待开始：有规范 | 保存失败可重试且不重复导出 |
| T07 Android热点集成 | 阻塞于B01/B02 | 无互联网、无路由器端到端完成 |
| T08 反向/多文件 | 待开始 | 角色矩阵、部分失败、小文件队列通过 |
| T09 iOS集成 | 待开始，早期探针阻塞 | 六方向与iOS生命周期通过 |
| T10 安装升级与发布 | 待开始 | 迁移、兼容、签名与用户独立试用通过 |

### 4.1 首批可领取任务

| 子任务 | 依赖 | 当前状态 | 退出门槛 |
| --- | --- | --- | --- |
| T01-01 Flutter 工程基线 | 无 | 已完成 | Android/Windows 启动同一壳应用，版本可追踪 |
| T01-02 CI 与检查 | T01-01 | 已完成 | format/analyze/test/build 可重复运行 |
| T02-01 Dart canonical manifest | T01-01、D03/D04 | 已完成 | 固定向量正反例一致，不复制 Python 实现逻辑 |
| T02-02 状态/错误/版本模型 | T01-01、D03 | 已完成 | 模型和序列化测试通过，未知字段规则明确 |
| T04-01 SQLite schema 与 chunk repository | B04 设备验证可后补 | 就绪（范围已定案，绑定已验证；实现进行中） | durable 提交顺序、迁移和故障测试通过 |
| T03-01 同网二维码配对 | T01-01/T02-02/B02 | 阻塞 | pin 先于令牌，正负例和目标端网络绑定通过 |
| T06-01 空间计划与导出 | T01-01/T04-01 | 待开始 | 分卷明细、unknown/不足、终检和幂等导出通过 |

领取和交付格式见 [Agent 任务手册](AGENT_TASK_PLAYBOOK.md)。子任务未满足依赖时不得通过演示代码绕过安全或持久化要求。

README的S1表示协议冻结阶段，对应T02后半段；S2/S3/S4是展示路线图。正式开发依赖与P0/P1/P2里程碑以技术方案第十三章为准，不能把S1“草案完成”解释为冻结完成。

## 5. 待人工重点复核

| 范围 | 复核要求 | 状态 |
| --- | --- | --- |
| TLS配对与凭证 | pin来源、所有证书必比对、令牌交付/撤销 | 待复核；本次仅验证loopback pin |
| 文件写入与checkpoint | 同步顺序、写入栅栏、实际平台耐久性 | 待真机及人工复核 |
| 协议冻结 | 双向角色、分页快照、恢复幂等与版本规则 | LFTM1/LFTC1 已由 Dart 独立实现复现一致（T02-01）；错误码/状态机/协商/幂等已收敛为可测试模型（T02-02）；**仍未冻结**，被下列三项草案缺口与原生实现比对阻塞 |
| **草案缺口：能力词表** | §3 写作 `capabilities:[...]` 却未定义任何能力标识；§17.1 要求「共有能力覆盖任务需求」 | **未定义，需维护者决定**。T02-02 已实现协商算法并用合成标识验证，但**不发明词表**（`AGENTS.md` §3）。**冻结前必须确定词表与「任务所需能力」的定义** |
| **草案缺口：终态无出边** | §10 只说明如何进入 `BLOCKED`/`FAILED`/`PARTIALLY_COMPLETED`，未定义如何离开 | **`failed` 与 `partiallyCompleted` 完全没有出边**，与 V2.1 §16.1「只重试失败项」冲突；**`blocked` 唯一出边是取消**，与 §11 对 `SPACE_INSUFFICIENT`「清理/换位置后重试」冲突，且取消会丢弃被承诺保留的恢复数据。已由 `statesWithoutDefinedExit` 与 `statesThatCanOnlyBeCancelled` 断言固定。**属协议变更，冻结前必须解决** |
| **草案缺口：文件级重试** | 文件状态机的 `failed` 无出边，无法表达「只重试失败项」 | 以 `FileStateMachine.retryOfFailedFilesIsDefined = false` 显式暴露并断言。**冻结前必须解决** |
| **NFC 路径强制** | 协议 §5.1 要求接收端拒绝非 NFC 规范的相对路径；检测需要 Unicode 规范化实现，Dart SDK 不提供 | **未实现，已登记为待人工决策**：选择实现属于依赖决策（`AGENTS.md` §3 禁止凭偏好定案）。候选：① 引入纯 Dart 规范化包；② 调用平台原生规范化 API；③ 由发送端负责并对摘要附加规范化声明。缺口以 `RelativePathRules.enforcesNfcNormalisation` 与一条断言显式暴露。**必须在协议冻结前解决** |
| 加密原语依赖 | SHA-256 实现的选择必须记录理由、许可证与安全影响 | 已引入 `crypto` 3.0.7（Dart 团队、BSD-3、纯 Dart、不接触文件/网络/密钥），见 [ADR-0002](decisions/ADR-0002-crypto依赖与SHA256.md)；自制加密算法已被明确否决 |
| SQLite 绑定 | `SYSTEM_ARCHITECTURE.md` §12 把 SQLite 插件列为待冻结；选择必须记录候选与验证结果 | 已选用 `sqlite3` 3.6.0（MIT、跨三端、可显式控制 PRAGMA 与事务），见 [ADR-0003](decisions/ADR-0003-SQLite绑定与耐久性配置.md)；探针在本机 5/5 通过（SQLite 3.53.4、`synchronous=FULL` 读回为 2）。**已移除已废弃且为空的 `sqlite3_flutter_libs`（`0.6.0+eol`）** |
| 平台 durable sync 语义 | 协议要求「durable sync 后才提交块」；`syncData` 的真实平台语义须由真机验证 | **未验证**。ADR-0003 只证明 PRAGMA 被接受与事务原子性，**不得**据此声称断电耐久性已验证；该结论属 B04 真机故障注入 |
| 导出/删除/迁移 | 不误删、不重复导出、迁移失败保留数据 | 尚未实现，后续必须复核 |
| 平台目录边界 | `android`/`windows`/`ios` 相对 `flutter create` 生成结果只允许标识类差异，不得混入业务逻辑 | T01-01 已按 SHA-256 逐文件审计通过，见 [平台目录审计](testing/evidence/2026-09-20/t01-01-01/platform-directory-audit.md)；后续每个平台任务需重复复核 |
| 依赖锁定 | `pubspec.lock` 必须入库；新增依赖需按端侧设计 §12 记录用途、许可证、维护状态与安全影响 | T01-01 已修正 `*.lock` 误忽略并跟踪 `pubspec.lock`；T01-01 未引入任何第三方运行时依赖 |
| 应用标识 | `applicationId` / bundle identifier 发布后不可更改 | 已在 [ADR-0001](decisions/ADR-0001-工程基线与标识.md) 冻结为 `com.nearsend.app`；变更必须在 T10 之前完成 |
| CI 门禁范围 | 自动化门禁只覆盖静态检查、单元/组件测试与构建；**不得**把它当作真机、网络、耐久性或安全结论的替代 | T01-02 已建立并在真实运行中通过，见 [运行汇总](testing/evidence/2026-09-20/t01-02-01/summary.md)；平台能力结论仍必须由目标设备证据支持 |
| CI 工具链与供应链 | Action 必须固定到提交 SHA、权限只读、禁止 `continue-on-error`；Flutter 版本与安装脚本两处必须一致 | 已由 `tooling/checks/check_ci_workflow.py` 在 CI 中强制 |

这些项阻止产品发布，不妨碍将明确标注为实验的源码和证据归档入仓。

## 6. 本次仓库交付与验证

- 新增 UI Baseline 1.0：精确 Design Token、组件规格、移动端四屏核心流程和 Windows 双栏传输页；SVG 已实际渲染检查。该状态只表示视觉设计完成，不表示 Flutter 页面已实现。
- 新增文档中心、Vibe Coding 流程、系统架构、应用与端侧服务、UI/UX、质量策略和 Agent 任务手册，并在 README 建立入口。
- 文档明确 NearSend 无中心云后台；“后台”是每台设备内嵌的本地 HTTPS 服务、传输引擎、SQLite 与平台适配。
- 建立需求/规格 → 任务 ID → 分支/PR → 测试证据 → 台账状态的追踪链，并拆出首批可领取子任务。
- 本次为文档与治理交付，未创建 Flutter 工程，也未改变任何真机或产品能力状态。
- 将协议和固定向量放入docs/protocol/；报告与原始证据放入docs/testing/；参考代码放入tooling/s0/。
- 仅修改向量路径等仓库集成细节，没有替换现有技术方案的产品摘要、发布渠道或AI规则。
- 更新README状态与文档入口；本台账是项目状态入口。
- 导入后执行 `cd tooling/s0 && python3 -m unittest -v test_probes`：24项通过，日志独立保存。
- 使用Python语法解析、相对文档链接检查、证据摘要校验和敏感文件检查验证导入。
- 未运行Flutter格式化/analyze/test：没有Flutter工程和SDK；没有Python格式化工具配置，本次不引入新工具或全量格式化。
- 未重复20GiB和小文件高成本实验：源码算法未变，历史原始证据完整保留。
- 未完成三端真机、真实断电、完整HTTP接口、生产背压、导出及迁移验证，详见阻塞表。

### 6.1 T01-01 Flutter 工程基线（本次交付）

任务卡：[T01-01](tasks/T01-01.md)　决策：[ADR-0001 工程基线与标识](decisions/ADR-0001-工程基线与标识.md)　
证据：[运行汇总](testing/evidence/2026-09-20/t01-01-01/summary.md)（运行 ID `t01-01-01`）

- 首次创建 Flutter 产品工程：`android`、`windows`、`ios` 三端平台目录，`lib/` 按
  `app / core / features` 分层，`test/` 覆盖构建信息、设计 Token、首页与版本信息页。
- 应用为**版本可追踪的壳**：显示应用版本、Git 提交（构建期 `--dart-define` 注入）、协议版本
  （明确标注 `1.0-draft1` 草案未冻结）与数据库 schema 版本（明确标注「已声明，数据库尚未创建」）。
  首页两个主操作**显式禁用并标注未实现**，未伪造任何业务能力。
- 新增 `tooling/scripts/check.ps1` 与 `build.ps1`：把 `AGENTS.md` §7 的必做检查与
  Android/Windows 构建固定为一组可复现命令，并把 Git 提交注入产物、输出产物 SHA-256。
- 新增 `docs/tasks/`（任务卡唯一存放位置，替代 GitHub Issue，理由见该目录 README）
  与 `docs/decisions/`（ADR-0001）。
- 修正根 `.gitignore` 中 `*.lock` 误忽略 `pubspec.lock` 的问题，满足 `AGENTS.md` §3 依赖锁定要求。
- 本机原先没有 Flutter/Dart SDK，`C:\tools\Android` 为空；本次安装 Flutter 3.47.5、
  Android SDK（platform-36、build-tools 36.0.0、NDK 28.2.13676358、platform-tools 37.0.1）
  并写入用户级环境变量。安装事实与脚本摘要记入 [environment.json](testing/evidence/2026-09-20/t01-01-01/environment.json)。
- 验证结果：`dart format` 无改动、`flutter analyze` 无问题、`flutter test` 29/29 通过、
  `tooling/s0` 24/24 通过；Android debug/release APK 与 Windows release 可执行文件均构建成功；
  release APK 在 **Xiaomi 25102RKBEC / Android 17 (API 37)** 真机安装并启动，
  版本信息页四项数值与构建提交一致；Windows 10 22H2 上可执行文件启动、窗口标题为 `NearSend`、
  键盘 `Tab`+`Enter` 可进入版本信息页。
- 平台目录经 SHA-256 逐文件审计，相对 `flutter create` 原始生成结果**只有标识类差异**，
  没有业务逻辑进入平台目录，见 [平台目录审计](testing/evidence/2026-09-20/t01-01-01/platform-directory-audit.md)。
- **附带修复**：`tooling/s0` 原先用不带编码的 `read_text()`/`write_text()` 处理 UTF-8 协议向量，
  在本机 `cp936` locale 下不可复现（实际 21 项运行、1 项失败）。已显式指定 UTF-8，并验证
  在 cp936 机器上重新生成向量得到字节相同的文件。原始失败日志保留未覆盖，见
  [S0 探针 Windows 复现](testing/evidence/2026-09-20/t01-01-01/s0-probe-baseline-on-windows.md)。
- **并入 UI Baseline 1.0**：本任务期间 PR #3 合并了 `docs/ui/STYLE_GUIDE.md` 并使其成为视觉权威。
  该指南推翻了原实现采用的两处数值（卡片圆角 12→**16**、按钮圆角 10→**12**），并新增
  `canvas`/`border`/`textMuted`/`primaryHover`/`primarySoft` 与三个语义 soft 背景、七级精确排版比例。
  `lib/app/theme/design_tokens.dart` 已按指南重写（`NearSendPalette` → `NearSendColors`），
  Flutter 测试由 29 项增至 36 项，并新增 canvas/card 区分、卡片 1dp 边框与语义色对比度检查。
  按 `AGENTS.md`「合并前处理基线变化并重新运行相关检查」，`origin/master` 已并入分支并解决
  §7 冲突后完整重跑全部检查与两端构建。
- 未执行/未完成：iOS 构建（本机无 macOS/Xcode，B06/T09 仍阻塞）；Windows 11 验证（本机为 Win10）；
  正式签名（T10）；深色模式、动态字体、屏幕阅读器与一万项列表性能（后续 UI 任务）；
  以及全部传输、配对、发现、存储与恢复能力（尚未实现）。

### 6.2 T01-02 CI 与检查（本次交付）

任务卡：[T01-02](tasks/T01-02.md)　证据：[运行汇总](testing/evidence/2026-09-20/t01-02-01/summary.md)（运行 ID `t01-02-01`）

- 新增 `.github/workflows/ci.yml`：四个作业（仓库检查、format/analyze/test、Android 构建、
  Windows 构建）。**没有任何 `continue-on-error`**，工作流权限为只读；
  所有 `uses:` 固定到 40 位提交 SHA，只使用 GitHub 官方一方 Action（MIT）。
- Flutter 工具链由 `tooling/ci/install_flutter.sh` 安装：版本固定 3.47.5 并**校验归档 SHA-256**
  （Linux `2132e990…`、Windows `0ccd7193…`，后者在 T01-01 中由本地实际下载独立核对）。
  不使用第三方 Action 安装 Flutter，理由与依赖评估记入运行汇总 §2。
- 新增 `tooling/checks/` 三个**仅用 Python 标准库**的检查：相对链接、敏感信息、CI 工作流不变量。
  `check.ps1` 与工作流调用同一份脚本，因此本地与 CI 执行同一组规则，不存在两套会分叉的实现。
- `build.ps1` 改为跨平台（搜索路径使用正斜杠），使 ubuntu 作业运行开发者本地使用的同一份构建逻辑，
  而不是在 YAML 里再写一遍。
- 新增 `.gitattributes` 声明行尾与二进制策略；`git add --renormalize .` 未改变任何既有文件内容。
- **真实 CI 结果**：首次运行（run 35521877748）3/4 作业通过，`Markdown relative links` 失败；
  修复后运行（run 35522211411，提交 `eb8c4d9`）**四个作业全部 success**。
  首次失败暴露了两个真实问题并已修复：检查器把文档中的行内代码示例当成真实链接；
  以及本地的「通过」只覆盖 26 个 Markdown 而 CI 看到 29 个（差额是当时尚未 `git add` 的新文档）。
  现在检查器会跳过代码块/行内代码/HTML 注释，并显式列出未跟踪的 Markdown 打印 `NOT CHECKED`。
  **首次失败的完整日志保留未覆盖**，见 `ci-run-35521877748-repository-checks-FAILED.log`。
- 反例验证：5 类缺陷（坏链接、假令牌、标签固定 Action、`continue-on-error`、Flutter 版本漂移）
  全部被对应检查抓到；敏感信息扫描的输出经过脱敏（只打印前 4 字符与长度）。
- 未执行/未完成：签名与发布作业（T10）；macOS runner 与 iOS 构建（B06/T09 仍阻塞）；
  pub/Gradle 依赖缓存优化；夜间集成测试与真机证据（按质量策略由里程碑任务承担）。

### 6.3 T02-01 Dart canonical manifest（本次交付）

任务卡：[T02-01](tasks/T02-01.md)　决策：[ADR-0002 crypto 依赖](decisions/ADR-0002-crypto依赖与SHA256.md)　
证据：[运行汇总](testing/evidence/2026-09-20/t02-01-01/summary.md)（运行 ID `t02-01-01`）

- 在 `lib/core/protocol/` 中**依据规范文本**实现 `LFTM1`（清单摘要）与 `LFTC1`（块清单摘要）：
  大端定宽写入器、§4 的十进制字符串/整数/UUID/摘要校验、§5.1 的相对路径词法规则、
  以及由文件大小与索引推导块长度与偏移的算术。
- **未逐行翻译 Python 参考实现**：编码器按协议 §5.2/§5.3 的字节布局描述编写，
  固定向量作为对规范理解的**外部检验**。三个向量（空文件、UTF-8 中文路径、4 MiB+3 字节尾块）
  的 `canonicalHex`、`manifestDigest`、`chunkManifestDigest` 全部逐字节一致。
- 显式断言 `manifestDigest != SHA-256(manifest JSON)`，证明没有走 §5.2 禁止的「哈希 JSON 文本」捷径；
  并验证 JSON 键序与空白不影响摘要、`files` 数组重排影响摘要。
- 反例覆盖：十进制非法形式、路径穿越/绝对路径/保留设备名/控制字符/孤立代理项/超过 1024 字节、
  未知与缺失字段、重复 `fileId`、超出 10,000 文件与 1,048,576 块、块缺失/重复/乱序/
  非末块短块、块长度与文件大小不符、摘要不匹配。
- 20 GiB 规模下块数 5120、高索引偏移大于 0xFFFFFFFF，验证 64 位算术；越界索引被拒绝而非回绕。
- 过程中发现并修复一个真实缺陷：路径校验把 `/` 误列为非法字符，而它是协议唯一允许的分隔符，
  导致任何带目录的路径（含中文向量）被拒绝。**只有真正跑固定向量才会暴露**，已修复并保留全部反例。
- 新增依赖 `crypto` 3.0.7，按端侧设计 §12 的九项要求记录为 ADR-0002；自制 SHA-256 被明确否决。
- **已知缺口**：协议 §5.1 要求的非 NFC 路径拒绝**未实现**，已登记在 §5 并需在协议冻结前解决。
- 未执行/未完成：完整错误模型与版本协商（T02-02）；原生（Kotlin/Swift/Windows）独立实现比对；
  流式哈希调度与读取用户文件（T03/T04）。

### 6.4 T02-02 状态、错误码和版本协商（本次交付）

任务卡：[T02-02](tasks/T02-02.md)　证据：[运行汇总](testing/evidence/2026-09-20/t02-02-01/summary.md)（运行 ID `t02-02-01`）

- 新增协议模型：`protocol_version.dart`（版本、能力与协商算法、冻结任务不可变判定）、
  `transfer_state.dart`（任务与文件状态机）、`retry_policy.dart`（超时、退避与抖动、Retry-After 上限）、
  `idempotency.dart`（`request_id` 幂等、`LeaseEpoch`/`LeaseGuard`、`ResumeCoordinator`）；
  并扩展 `protocol_exception.dart` 为 §11 的完整错误模型。
- 错误模型把「能否重试」当作线上契约（§7 的错误体含 `retryable`）：**只有** §11 要求退避的
  `RATE_LIMITED`/`STORAGE_SYNC_FAILED`/`DB_COMMIT_FAILED` 可自动重试；
  `SPACE_INSUFFICIENT` 明确不可自动重试，因为它需要用户先采取行动。
- 状态机的每条迁移都标注来源（`stated`/`derived`）并在 rationale 中引用 §10，
  测试断言「每条迁移都有依据」，使表格无法悄悄扩张。
- `ResumeCoordinator` 固定 §9 的顺序：同 ID 不同参数 → 冲突；在途 → 202 语义；
  已完成 → 重放且**不再升代**；已有更高世代 → `STALE_RESUME_REQUEST`；否则分配新世代。
- 新增 79 项协议测试（48 → 127），Flutter 测试总数 84 → 163。
- **发现并登记三处草案缺口**（见 §5）：能力词表未定义；`BLOCKED`/`FAILED`/`PARTIALLY_COMPLETED`
  无出边，其中 `blocked` 只能取消、与 §11 的处方冲突；文件级 `failed` 无出边，无法「只重试失败项」。
  三者都以可执行断言固定，属**协议变更**，冻结前必须解决。
- 未执行/未完成：协议冻结本身；HTTP 服务器与路由（T03-01）；幂等与世代的持久化（T04-01，
  必须与效果同事务提交）；能力词表取值；原生实现比对。

## 7. 更新记录与维护规则

| 日期 | 变更 | 证据 |
| --- | --- | --- |
| 2026-09-20 | 产品方向、开发顺序和严格校验取舍确认 | 技术方案V2.1 |
| 2026-09-20 | 完成Linux参考实验及协议draft1 | 原始日志、JSON结果和报告 |
| 2026-09-20 | 导入仓库、完成24项复测、建立本台账 | 本次Git提交/PR、repository-import-tests.log |
| 2026-09-20 | 建立 Vibe Coding 研发流程、实施架构、端侧/UI/质量规格和 Agent 任务手册 | D06–D12、本次文档 PR |
| 2026-09-20 | 完成 UI Baseline 1.0、组件样式和移动端/Windows视觉稿 | D10、UI设计PR |
| 2026-09-20 | T01-01 完成：创建三端 Flutter 工程与版本壳应用，Android 真机与 Windows 构建/运行通过，建立任务卡与 ADR 目录，修正 `pubspec.lock` 与 S0 探针编码缺陷 | [T01-01](tasks/T01-01.md)、[运行汇总](testing/evidence/2026-09-20/t01-01-01/summary.md)、[PR #4](https://github.com/yanzhao77/NearSend/pull/4) |
| 2026-09-20 | 修正 T02-01/T02-02 依赖列（实际依赖 T01-01 工程），B01–B04 阻塞口径按新环境更新 | 本台账 §3、§4.1 |
| 2026-09-20 | T01-01 并入 UI Baseline 1.0：设计 Token 按 `docs/ui/STYLE_GUIDE.md` 重写（圆角 16/12、新增 canvas/border/muted/soft 与精确排版比例） | [样式指南](ui/STYLE_GUIDE.md)、[PR #4](https://github.com/yanzhao77/NearSend/pull/4) |
| 2026-09-20 | T01-01 经 PR #4 合并入 `master`（合并提交 `5a3d840`），任务状态由「已完成（待合并）」转为「已完成」 | [PR #4](https://github.com/yanzhao77/NearSend/pull/4)、合并提交 `5a3d840` |
| 2026-09-20 | 构建脚本修订：产物摘要排除本次运行自身重写的证据日志，使干净提交的构建立即体现为 `gitDirty=false`；修复该判定在 `Set-StrictMode` 下对单个变更路径报错的问题。证据按新的干净修订重新采集 | [build.ps1](../tooling/scripts/build.ps1)、T01-01 证据 |
| 2026-09-20 | T01-02 完成：建立 GitHub Actions 门禁（仓库检查、format/analyze/test、Android/Windows 构建），固定并校验 Flutter 工具链摘要，新增三项跨平台仓库检查与 `.gitattributes`；真实 CI 首次失败后修复并全部通过 | [T01-02](tasks/T01-02.md)、[运行汇总](testing/evidence/2026-09-20/t01-02-01/summary.md)、[PR #6](https://github.com/yanzhao77/NearSend/pull/6) |
| 2026-09-20 | 记录一条过程教训：仓库级检查只扫描已跟踪文件，因此**本地通过不代表覆盖工作区**。检查器现在会列出未跟踪的 Markdown 并打印 `NOT CHECKED` | T01-02 运行汇总 §6、`ci-run-35521877748-repository-checks-FAILED.log` |
| 2026-09-20 | T02-01 待验证：Dart 独立实现 LFTM1/LFTC1，三个固定向量逐字节一致；新增 `crypto` 依赖（ADR-0002）；登记非 NFC 路径强制缺口 | [T02-01](tasks/T02-01.md)、[运行汇总](testing/evidence/2026-09-20/t02-01-01/summary.md)、[ADR-0002](decisions/ADR-0002-crypto依赖与SHA256.md) |
| 2026-09-20 | D04 由「待 Dart/原生独立比对」更新为「已有 Dart 独立比对」；T02 说明补充 Dart 实现已一致 | 本台账 §2、§4 |
| 2026-09-20 | T01-02 经 PR #6（合并提交 `9d784a4`）与 PR #7（合并提交 `11d4304`）合并入 `master`；CI 在 `master` 上同样全部通过（run 35522441321） | [PR #6](https://github.com/yanzhao77/NearSend/pull/6)、[PR #7](https://github.com/yanzhao77/NearSend/pull/7) |
| 2026-09-20 | T02-01 经 PR #8 合并入 `master`（合并提交 `214f519`），任务状态由「待验证」转为「已完成」 | [PR #8](https://github.com/yanzhao77/NearSend/pull/8)、合并提交 `214f519` |
| 2026-09-20 | T02-02 待验证：错误模型、状态机、版本/能力协商、超时重试、`request_id` 幂等与 `lease_epoch` 收敛为可测试模型（协议测试 48→127，总计 163） | [T02-02](tasks/T02-02.md)、[运行汇总](testing/evidence/2026-09-20/t02-02-01/summary.md) |
| 2026-09-20 | **发现三处协议草案缺口并登记**：能力词表未定义；`BLOCKED`/`FAILED`/`PARTIALLY_COMPLETED` 无出边（`blocked` 只能取消，与 §11 处方冲突）；文件级 `failed` 无出边，无法「只重试失败项」。三项均属协议变更，**冻结前必须解决** | 本台账 §5、T02-02 运行汇总 §4 |
| 2026-09-20 | T02-02 经 PR #10 合并入 `master`（合并提交 `29ed41c`），任务状态由「待验证」转为「已完成」；CI 四个作业在首次运行即全部通过（run 35525798037） | [PR #10](https://github.com/yanzhao77/NearSend/pull/10)、合并提交 `29ed41c`、T02-02 证据 |
| 2026-09-20 | T04-01 由「待澄清」转为「就绪」：范围写入任务卡；SQLite 绑定按 §12 完成候选评估与实测验证（ADR-0003），并移除已废弃且为空的 `sqlite3_flutter_libs`。schema/迁移/repository 实现尚未开始 | [T04-01](tasks/T04-01.md)、[ADR-0003](decisions/ADR-0003-SQLite绑定与耐久性配置.md)、[绑定验证证据](testing/evidence/2026-09-20/t04-01-01/summary.md) |

每次改变状态同时更新证据链接、适用环境、阻塞和下一动作；真实失败不得覆盖为“待验证”。历史证据不覆盖，新增运行按日期/运行ID归档。Git提交及PR提供版本追踪，不在同一提交正文猜测尚未生成的SHA。只有目标端退出门槛通过才能将平台项目从“阻塞/部分完成”改为“已完成”。
