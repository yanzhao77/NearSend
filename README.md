<div align="center">

# NearSend · 近传

### 不经过互联网，让手机与电脑在本地 Wi-Fi 上安全传输大文件。

[![Project Status](https://img.shields.io/badge/status-S0%20active%20%7C%20preview-F5A623?style=for-the-badge)](#项目状态)
[![Latest Release](https://img.shields.io/github/v/release/yanzhao77/NearSend?display_name=tag&style=for-the-badge&color=2EA44F)](https://github.com/yanzhao77/NearSend/releases/latest)
[![Flutter](https://img.shields.io/badge/Flutter-3.47.5-02569B?style=for-the-badge&logo=flutter&logoColor=white)](https://flutter.dev/)
[![Platforms](https://img.shields.io/badge/platforms-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20Linux-536DFE?style=for-the-badge)](#现在就下载)
[![License](https://img.shields.io/badge/license-MIT-2EA44F?style=for-the-badge)](LICENSE)

**本地直连 · 流式传输 · 严格校验 · 持久化断点续传设计**

</div>

---

## 现在就下载

截至 2026-09-26，最新 GitHub 预览版是 **[v0.1.10](https://github.com/yanzhao77/NearSend/releases/tag/v0.1.10)**，对应 `master` 合并提交 `e1cfb30`，仅适合内部预览和验证。自动发布只接受 `master` 成功 CI 的精确提交；手动发布也必须指定并核验目标提交。

| 平台 | 安装包 | 说明 |
| --- | --- | --- |
| Android | [APK](https://github.com/yanzhao77/NearSend/releases/download/v0.1.10/NearSend-0.1.10-android.apk) | 当前使用 debug signing，仅供内部测试；不能作为正式升级链 |
| Windows x64 | [ZIP](https://github.com/yanzhao77/NearSend/releases/download/v0.1.10/NearSend-0.1.10-windows-x64.zip) | 解压后运行桌面程序 |
| macOS | [ZIP](https://github.com/yanzhao77/NearSend/releases/download/v0.1.10/NearSend-0.1.10-macos.zip) | 未签名、未 notarization |
| Linux amd64 | [DEB](https://github.com/yanzhao77/NearSend/releases/download/v0.1.10/NearSend-0.1.10-linux-amd64.deb) · [便携包](https://github.com/yanzhao77/NearSend/releases/download/v0.1.10/NearSend-0.1.10-linux-x64.tar.gz) | 当前只构建 amd64 |
| 校验 | [SHA256SUMS.txt](https://github.com/yanzhao77/NearSend/releases/download/v0.1.10/SHA256SUMS.txt) | 发布流水线自动生成 |

> **预览版本边界**：构建产物和代码级双节点测试已经由 CI 验证，但 Android ↔ Windows 的真实设备双向大文件传输、断点恢复和正式签名发布仍未完成。不要把当前 APK、ZIP 或 DEB 当作稳定版或商店发行包。

## NearSend 是什么？

NearSend 是一款面向手机与电脑的跨平台离线文件互传工具。它不依赖互联网、云服务器或账号系统：设备通过现有局域网连接，或由 Android 创建本地热点，再使用经过身份验证的 HTTPS 通道直接传输文件。

这里的“离线”是指**不需要互联网**，不是不需要网络。两台设备仍必须拥有可用的本地 Wi-Fi 链路。

NearSend 的重点是可靠性：文件通过流式读写和有界缓冲处理，按块校验并把接收方已提交的 checkpoint 作为恢复依据，让网络中断、进程退出和设备重启后的恢复行为可验证、可诊断。

## 当前能做什么

| 方向 | 当前状态 |
| --- | --- |
| 协议与数据模型 | `LFTM1` / `LFTC1` 清单编码、状态模型、错误模型和固定向量已有 Dart 独立实现；协议仍是草案，尚未冻结 |
| 安全控制面 | TLS 1.3 下限、证书指纹绑定、一次性配对令牌、会话授权和控制端点已有实现与测试 |
| 数据面 | SQLite manifest staging、授权、分块读写、终检与导出编排已有代码级测试；断点恢复的应用层编排仍在进行 |
| Flutter 应用 | Android、Windows、iOS 工程和 T12 共享 UI 基线已建立；Android/iOS 首页扫一扫入口、运行时相机权限检查、扫码后自动连接及失败返回提示已合并到 master。2026-09-26 在 25102RKBEC / Android 17 上相机权限请求成功，但 `mobile_scanner` 启动相机报 `genericError` / native `NullPointerException`，未完成扫码；Android ↔ Windows 实机配对仍未建立 |
| 自动化发布 | `master` 的 CI 成功后自动构建 Android、Windows、macOS、Linux 并创建 GitHub Release，附带 release notes 与 SHA-256 清单 |

**当前没有承诺的能力**：互联网远程传输、云端中转、BLE 文件承载、目录实时同步、后台无限运行、Windows MSIX、Android Play/AAB、正式代码签名和 iOS 发布。

## 核心设计

```mermaid
flowchart LR
    A[本地 Wi-Fi] --> B[二维码与 TLS 身份校验]
    B --> C[清单与授权]
    C --> D[流式分块传输]
    D --> E[SQLite checkpoint]
    E --> F[整文件校验与导出]
```

- **一个共享协议核心**：协议字段、状态机、错误码、块摘要和版本规则不能由平台各自解释。
- **接收方是断点权威**：只有已经写入、校验并在 SQLite 中提交的块才算恢复进度。
- **先验证身份，再交付令牌**：二维码中的 TLS 指纹必须先匹配；不支持全局信任证书或明文降级。
- **不把整文件读入内存**：大文件使用流式读写、有界缓冲和背压，哈希与磁盘操作不阻塞 Flutter UI isolate。
- **平台差异留在适配层**：Android SAF URI、iOS 安全作用域资源和 Windows 存储句柄不能被业务层当作普通路径。

## 架构概览

```mermaid
flowchart TB
    UI[Flutter UI] --> APP[应用服务与任务编排]
    APP --> CORE[共享协议核心]
    CORE --> NET[HTTPS / 发现 / 配对]
    CORE --> STORE[SQLite / 分块 / checkpoint]
    NET --> NATIVE[Android · Windows · iOS 原生适配]
    STORE --> NATIVE
```

## 路线图

| 阶段 | 目标 | 状态 |
| --- | --- | --- |
| S0 | 验证 Flutter I/O、TLS、SQLite 耐久性、局域网组网和平台文件边界 | **进行中；UI 基线已合并，平台证据待补** |
| S1 | 冻结协议 v1、清单规范、状态机、错误码和固定测试向量 | 草案与参考向量已完成；冻结待完成 |
| S2 | Android + Windows 真实设备端到端小文件与大文件传输 | 代码级闭环已有；真机闭环待完成 |
| S3 | 暂停、故障恢复、重启续传、空间管理与安全验收 | 进行中，应用层 resume 和设备证据待补 |
| S4 | iOS 正式集成、设备矩阵测试和发布准备 | 待开始 |

## 项目状态

NearSend 当前处于 **S0 技术验证和协议细化阶段**。仓库已有协议、配对、存储、分块、终检、UI 装配和 GitHub 发布流水线的可审阅实现；但这些实现必须和对应证据一起阅读，不能把“代码存在”“单元测试通过”或“CI 构建成功”当作完整产品验收。

截至 **2026-09-26**：

- 最新预览版 [v0.1.10](https://github.com/yanzhao77/NearSend/releases/tag/v0.1.10) 已由 GitHub Actions 发布，目标提交为 `e1cfb30541106a39a8aba2087bf6906dcbdf60a8`，包含 Android APK、Windows x64 ZIP、macOS ZIP、Linux amd64 DEB/便携包和 `SHA256SUMS.txt`；仍不代表正式签名或双机产品验收完成。
- 首页与传输导航 [PR #71](https://github.com/yanzhao77/NearSend/pull/71)、首页扫一扫并自动连接 [PR #73](https://github.com/yanzhao77/NearSend/pull/73)、逐次检查相机权限及扫码/连接失败返回提示 [PR #74](https://github.com/yanzhao77/NearSend/pull/74) 均已合并到 `master`；分别进入 v0.1.7、v0.1.9 和 v0.1.10。2026-09-26 真机相机权限弹窗通过，但相机启动失败，实际扫码尚未通过；Android ↔ Windows 双向传输、断网重连和大文件断点恢复仍未执行，详情见[验收记录](docs/releases/1.2/ACCEPTANCE.md)。
- T12 UI 全平台改造已通过 [PR #61](https://github.com/yanzhao77/NearSend/pull/61) squash 合并到 `master`，合并提交为 `880dfb8`；共享主题、组件、响应式应用壳、真实任务/空间/设置读模型、配对/发送/接收/任务页面和平台适配代码已进入主干。
- UI 代码级验收已归档，覆盖 Light/Dark、动态字体 200%、窄屏、长文案、空间 `sufficient`/`insufficient`/`unknown`、五阶段传输状态和真实数据库读模型；这些结果不替代目标设备验收。
- 控制面、数据面和界面已有“真实两个节点 + 真实 TLS”的代码级测试，覆盖清单、授权、分块、校验和导出路径。
- NearSend 1.2 升级已按 [开发计划](docs/releases/1.2/PLAN.md) 推进至 V12-12 当前环境验收；
  [状态](docs/releases/1.2/STATUS.md) 和 [验收记录](docs/releases/1.2/ACCEPTANCE.md) 分别记录已实现能力与
  未完成的 PAKE、指定网络绑定、Windows 自动入网和真实双机矩阵，不把自动化结果写成实机结论。
- Android、Windows 的真实设备双向传输、大文件恢复、Android SAF 与 Windows 取件器仍需目标设备证据；Windows release 已由 PR CI 构建，但 Windows 截图/键盘/系统交互和 iOS 真机构建/生命周期/屏幕阅读器验证仍受环境限制，当前不能宣称跨平台产品闭环已验收。
- Android 当前使用 debug signing；macOS 未签名、未 notarization；Linux 仅构建 amd64。正式签名材料必须通过受保护的 GitHub Environment 注入，不能提交到仓库。

查看 [项目现状与进度台账](docs/PROJECT_LEDGER.md)、[T12 UI 最终验收证据](docs/testing/evidence/2026-09-22/t12-ui/t12-10-final-acceptance.md)、[MVP 验证证据](docs/testing/evidence/2026-09-22/t11-mvp-bidirectional/summary.md)、[S0 验证报告](docs/testing/S0-report.md) 和 [GitHub Actions 自动发版说明](docs/releases/GITHUB_ACTION_RELEASES.md)。

## 自动发版

`.github/workflows/ci.yml` 负责仓库检查、格式化、静态分析、测试以及 Android/Windows 构建。CI 在 `master` 成功后，`.github/workflows/release.yml` 自动：

1. 以已有最高版本 tag 为基线递增 patch 版本；
2. 在原生 runner 上构建 Android、Windows、macOS 和 Linux 安装包；
3. 生成 GitHub 自动 release notes，并追加构建 commit、Flutter 版本、架构和签名限制；
4. 计算并上传 `SHA256SUMS.txt`；
5. 创建带版本 tag 的 GitHub Release。

也可以从 GitHub Actions 页面手动触发 `workflow_dispatch`。发布设计、签名阻断项和当前资产清单见 [发布说明](docs/releases/GITHUB_ACTION_RELEASES.md)。

## 文档入口

- [文档中心与推荐阅读顺序](docs/README.md)
- [项目现状与进度台账](docs/PROJECT_LEDGER.md)
- [任务卡索引](docs/tasks/README.md)
- [协议 v1.0-draft1](docs/protocol/v1.0-draft1.md) · [固定测试向量](docs/protocol/vectors-v1.json)
- [系统架构](docs/architecture/SYSTEM_ARCHITECTURE.md) · [应用与端侧服务设计](docs/architecture/APP_AND_SERVICE_DESIGN.md)
- [UI/UX 与视觉规范](docs/ui/UI_UX_SPEC.md) · [质量与验收策略](docs/testing/QUALITY_AND_ACCEPTANCE.md)
- [GitHub Actions 自动发版](docs/releases/GITHUB_ACTION_RELEASES.md)
- [NearSend 1.2 计划](docs/releases/1.2/PLAN.md) · [开发状态](docs/releases/1.2/STATUS.md) · [验收记录](docs/releases/1.2/ACCEPTANCE.md)
- [AI 与贡献者开发规则](AGENTS.md) · [开发流程](docs/DEVELOPMENT_WORKFLOW.md)

`AGENTS.md` 是本项目对 Codex、Cursor、Claude Code 等 AI 编码工具的最高优先级规则，包含架构边界、安全要求、目录规范、开发工作流和必做检查。

## 参与项目

欢迎围绕以下方向提交 Issue 或 Pull Request：

- Flutter 跨平台大文件 I/O、背压和恢复编排
- Android/Windows/iOS 本地网络、文件授权和平台适配
- TLS 身份绑定与离线二维码配对
- SQLite checkpoint、崩溃一致性和故障注入测试
- 可访问、可理解的传输、恢复和空间预检交互

贡献前请先阅读 [AGENTS.md](AGENTS.md)、[开发流程](docs/DEVELOPMENT_WORKFLOW.md) 和 [Agent 任务手册](docs/AGENT_TASK_PLAYBOOK.md)。提交必须保持改动聚焦，并且不能包含密钥、用户数据、构建产物或大文件样本。

## License

[MIT License](LICENSE) © 2026 Azir

<div align="center">

**NearSend — Your files. Your devices. No cloud required.**

</div>
