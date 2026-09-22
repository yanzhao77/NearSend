# T11-01 双向互传 MVP —— 本阶段的验证证据与状态（2026-09-22）

本文件把「已经验证过什么、由哪条用例验证、还剩什么没做」集中在一处，避免台账的长篇叙述被
摘引成更强的结论。**结论先行：两个方向的数据面与界面都已用「真实两个节点 + 真实 TLS + 两端都是
产品代码」的用例验证过，但尚未在真实 Android 设备上执行过任何一次；设备安装被系统弹窗阻塞。**

## 1. 已经验证的（每条都能对到具体用例）

| 断言 | 用例 | 端到端到什么程度 |
| --- | --- | --- |
| 提供式发送：一端 `SendingFlow`(offer) 提供，另一端 `ReceivingFlow` 接收，磁盘文件 SHA-256 与发送端读到的文件相同 | `test/features/transfer/paired_nodes_test.dart` | 真实两个节点、真实 TLS、**两端都是产品流程**，无测试侧代劳 |
| 推送式接收：一端 `SendingFlow`(push) 推送，另一端 `ServerReceivingFlow` 受理并收尾，磁盘文件 SHA-256 相同 | `test/features/transfer/server_receiving_flow_test.dart` | 同上 |
| 界面上「连接 → 选择 → 发送」把文件送到对端磁盘 | `test/app/app_test.dart`（发送用例） | 两个真实节点、真实 TLS、经界面驱动；载荷为单块 4 KiB |
| 界面上「接收文件 → 查看对方提供 → 填目录 → 接受」把文件存到本机 | `test/app/app_test.dart`（接收用例） | 同上 |
| 界面上受理**推送**（本机作为服务端）并保存 | `test/app/app_test.dart`（推送用例） | 同上 |
| 受理前的空间预检：可证明装不下则拒绝，且不留下授权、不创建目录 | `test/features/transfer/server_receiving_flow_test.dart`（短信用例） | 真实两节点 |
| 发送端等待对方决定而不是把字节送进拒绝；失败有界且成句 | `test/features/transfer/sending_flow_test.dart` | 真实两节点 |
| 指纹不符立即中止，且**对端的一次性令牌事后仍可用**（证明错误 pin 从未到达服务端） | `test/app/peer_session_test.dart` | 真实 HTTPS 服务端 |
| 应用私有目录：Android 走通道、桌面走 `%LOCALAPPDATA%`、都取不到就拒绝启动 | `test/platform/app_directories_test.dart` | 契约测试（Android 分支用 mock channel） |

**全部自动化检查**：`dart format`（无改动）、`flutter analyze`（无问题）、`flutter test`
（**1230 项通过**）、`tooling/checks/check_links.py`、`check_secrets.py`、`check_ci_workflow.py`、
`git diff --check`。

**CI**：分支 `feat/mvp-bidirectional-transfer` 上最近一次完整运行（head `0b25597`）四个作业全部通过：
仓库检查、格式/分析/测试、Windows 构建、Android 构建。

## 2. 没有验证的（不得被上文读成已验证）

- **真机**：本轮再次尝试安装（第 **12** 次）仍为
  `INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`。设备 `22081283C` 已连接、屏幕已点亮，
  该错误是设备上的**安装确认弹窗**（或开发者选项里的「USB 安装」开关）造成的，不是配置错误：
  `adb_install_need_confirm=0`、`verifier_verify_adb_installs=0` 均已确认无效。
  因此本项目**从未在 Android 上运行过**：包括应用的节点启动、`applicationDirectory` 通道、
  SAF 通道、以及任何一次真实文件传输。
- **Windows → Android 真机方向**：无。（历史上仅有 Android → Windows 的 harness 证据，
  且那是测试驱动的节点，不是应用界面。）
- **界面级端到端的两处限制**：`test/app/app_test.dart` 的载荷是**单块 4 KiB**——在
  `testWidgets` 的虚拟时钟区里，多块载荷写不完（接收端始终 0 字节），多块/多兆字节路径由
  `sending_flow_test`/`server_receiving_flow_test` 在 widget binding 之外覆盖。
- **空间预检**：没有平台测量通道，界面上按 `unknown` 如实呈现「未做空间预检」。
- **断点续传**：底层能力（已提交行、`checkpointSeq`、`leaseEpoch`、每块一个部件文件）齐备并有测试，
  但**应用层没有编排**，界面也还没有恢复入口。
- **Windows 取件器**：没有。发送要手输路径，接收要手输保存目录。
- **身份持久化**：没有。连接页如实说明每次启动 pin 会变。

## 3. 真机验证步骤（唯一剩余的人工环节）

1. 在设备上允许「通过 USB 安装应用」（开发者选项），或唤醒设备后确认安装弹窗，然后：
   `adb install -r build/app/outputs/flutter-apk/app-debug.apk`
2. Windows 端：`flutter run -d windows`；Android 端打开应用。
3. 两端各自进入「接收文件 / 发送文件」的连接页，**互相粘贴对方的连接信息**并连接
   （只粘贴一侧也可传：被粘贴的一台可以发送，粘贴的那一台可以接收推送）。
4. 发送端选择文件（Android 系统选择器 / Windows 输入路径）→「发送」；接收端等待条目出现 →
   填写保存目录 →「接受并接收」或「接受这次发送」。
5. 记录证据：两端 pin、两端文件的**长度与 SHA-256**（必须相同）、两端任务状态与界面文案。

## 4. 与台账、任务卡的关系

- 交付记录逐条在 [项目台账](../../../../PROJECT_LEDGER.md) §6.4（`t11-01-01` … `t11-01-28`）。
- 验收条件与进度表在 [T11-02](../../../../tasks/T11-02.md)。
- 本文件只做汇总与口径固定：**在没有第 3 节的记录之前，不得声称 Android↔Windows 互传已验证。**
