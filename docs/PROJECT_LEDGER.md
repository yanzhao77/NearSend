# NearSend 项目现状与进度台账

更新日期：2026-09-20。范围：技术方案V2.1、协议草案、S0参考实验、研发治理与实施规格。后续以本文件最新Git版本为准，不用聊天记录代替状态。

## 一句话现状

**S0进行中：产品方向、实施架构、端侧分层、UI/UX、质量门禁和 Agent 工作流已形成设计基线；协议草案与 Python 参考实验已完成；T01-01 已建立 Android/Windows/iOS 三端 Flutter 工程与版本可追踪的壳应用，并在 Android 真机与 Windows 上构建运行通过。传输、配对、发现、存储与恢复功能均未实现；没有可分发安装包或正式发布版本；协议与关键平台选型尚未冻结。**

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
| D04 | 固定编码/摘要向量 | 部分完成 | [向量](protocol/vectors-v1.json) | Python参考生成，待Dart/原生独立比对 |
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
| T01 工程/构建/配置 | 已完成 | Android、Windows 构建成功并可安装/运行；版本、Git 提交、协议版本与 schema 版本在两端可见（见 §6.1） |
| T02 协议/模型/向量 | 部分完成 | 草案和Python向量已提交；需跨语言一致并冻结 |
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
| T01-02 CI 与检查 | T01-01 | 就绪 | format/analyze/test/build 可重复运行 |
| T02-01 Dart canonical manifest | T01-01、D03/D04 | 就绪（依赖 T01-01 工程） | 固定向量正反例一致，不复制 Python 实现逻辑 |
| T02-02 状态/错误/版本模型 | T01-01、D03 | 就绪（依赖 T01-01 工程） | 模型和序列化测试通过，未知字段规则明确 |
| T04-01 SQLite schema 与 chunk repository | B04 设备验证可后补 | 待澄清 | durable 提交顺序、迁移和故障测试通过 |
| T03-01 同网二维码配对 | T01-01/T02-02/B02 | 阻塞 | pin 先于令牌，正负例和目标端网络绑定通过 |
| T06-01 空间计划与导出 | T01-01/T04-01 | 待开始 | 分卷明细、unknown/不足、终检和幂等导出通过 |

领取和交付格式见 [Agent 任务手册](AGENT_TASK_PLAYBOOK.md)。子任务未满足依赖时不得通过演示代码绕过安全或持久化要求。

README的S1表示协议冻结阶段，对应T02后半段；S2/S3/S4是展示路线图。正式开发依赖与P0/P1/P2里程碑以技术方案第十三章为准，不能把S1“草案完成”解释为冻结完成。

## 5. 待人工重点复核

| 范围 | 复核要求 | 状态 |
| --- | --- | --- |
| TLS配对与凭证 | pin来源、所有证书必比对、令牌交付/撤销 | 待复核；本次仅验证loopback pin |
| 文件写入与checkpoint | 同步顺序、写入栅栏、实际平台耐久性 | 待真机及人工复核 |
| 协议冻结 | 双向角色、分页快照、恢复幂等与版本规则 | 草案待独立实现验证 |
| 导出/删除/迁移 | 不误删、不重复导出、迁移失败保留数据 | 尚未实现，后续必须复核 |
| 平台目录边界 | `android`/`windows`/`ios` 相对 `flutter create` 生成结果只允许标识类差异，不得混入业务逻辑 | T01-01 已按 SHA-256 逐文件审计通过，见 [平台目录审计](testing/evidence/2026-09-20/t01-01-01/platform-directory-audit.md)；后续每个平台任务需重复复核 |
| 依赖锁定 | `pubspec.lock` 必须入库；新增依赖需按端侧设计 §12 记录用途、许可证、维护状态与安全影响 | T01-01 已修正 `*.lock` 误忽略并跟踪 `pubspec.lock`；T01-01 未引入任何第三方运行时依赖 |
| 应用标识 | `applicationId` / bundle identifier 发布后不可更改 | 已在 [ADR-0001](decisions/ADR-0001-工程基线与标识.md) 冻结为 `com.nearsend.app`；变更必须在 T10 之前完成 |

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
- 未执行/未完成：iOS 构建（本机无 macOS/Xcode，B06/T09 仍阻塞）；Windows 11 验证（本机为 Win10）；
  正式签名（T10）；深色模式、动态字体、屏幕阅读器与一万项列表性能（后续 UI 任务）；
  以及全部传输、配对、发现、存储与恢复能力（尚未实现）。

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
| 2026-09-20 | T01-01 并入 UI Baseline 1.0：设计 Token 按 `docs/ui/STYLE_GUIDE.md` 重写（圆角 16/12、新增 canvas/border/muted/soft 与精确排版比例） | [样式指南](ui/STYLE_GUIDE.md)、本次 PR |

每次改变状态同时更新证据链接、适用环境、阻塞和下一动作；真实失败不得覆盖为“待验证”。历史证据不覆盖，新增运行按日期/运行ID归档。Git提交及PR提供版本追踪，不在同一提交正文猜测尚未生成的SHA。只有目标端退出门槛通过才能将平台项目从“阻塞/部分完成”改为“已完成”。
