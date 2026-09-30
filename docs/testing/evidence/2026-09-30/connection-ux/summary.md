# 连接交互重构实施与验收记录

日期：2026-09-30。基线：`64a2582cfab137a1735d0e8f07cecbebff253095` / v0.1.17 Preview。实施分支：`refactor/connection-ux`。方案：[连接交互重构](../../../../architecture/CONNECTION_UX_REFACTOR_PLAN.md)。

状态：代码实现完成；本地自动化结果如下；目标平台构建以 [PR #82 的 CI](https://github.com/yanzhao77/NearSend/pull/82/checks) 为准。设备验收未完成，不宣称稳定版交付。此记录只使用合成文件和受控本地节点，不保存二维码载荷、令牌或恢复密钥。

## 入口替换及实现边界

| 原行为 | 当前行为 | 实现 |
|---|---|---|
| 本机设备进入混合连接页 | 只显示当前本机 QR、有效期、配对状态及显式刷新 | `LocalDeviceQrPage`；签发时间由 `NodeSession` 持有，打开页面不作废邀请 |
| 首页扫码进入表单 | 权限复核后直接进入专用扫描器；Windows 直接使用图片选择器 | `NearSendApp._scanFromHome`，相同严格载荷解析器 |
| 扫码后显示连接信息 | 独立进度模态反馈，完成回到首页 | `PairingCoordinator` / `PairingProgressDialog` |
| 发现项被当成可连接设备 | 显示配对引导；扫描对方 QR 才认证 | `_showDevice`；BLE 文案明确传输仍需本地 Wi-Fi |
| 点击已连接项重新出现表单 | 设备操作卡片；关闭不改变授权 | `ConnectedDeviceCard`；显示真实任务数与会话状态 |
| 灯灭时重新配对 | 在线证明与授权分开，过期卡片仍可断开 | `DeviceConnectionRef` + 实际授权查询，不按 `isReady` 推断是否可信 |
| 手动粘贴混入普通操作 | 设置 → 高级连接 | `/settings/advanced-connection`，成功清输入并移除自身路由 |
| 旧连接页残留 | 删除 `ConnectionPage`、`/connect`、字符串入口参数与调用方 | `transfer_pages.dart` 保留任务详情等非连接职责 |

没有新增协议字段、数据库 schema、第三方依赖或宽松 TLS 验证。既有 bootstrap/network lease、安全 pin 和一次性令牌逻辑继续使用。Windows 图片导入保持原解码器；其他不支持的桌面平台使用高级文本入口。

## 状态、资源与异步操作

协调器管理 `idle → joiningNetwork/verifyingIdentity → connected/failed`，同一时间只允许一个交互式连接尝试。入口层另有 busy 标志防重复扫码；已有出站连接不能被新扫码静默替换。尝试代次用于识别取消、销毁及晚到结果，`PeerSession` 同样保护握手结果，晚到客户端关闭且不能覆盖较新的成功会话。

尝试只释放自己取得的 Wi-Fi lease。已建立会话与传输属于应用层，扫码器、二维码页和设备卡片退出不会销毁活动传输。后台切换会取消交互式尝试并移除它所持有的连接模态；扫描器停止相机并返回。精确保存并移除自己的 `DialogRoute` 和设备卡片路由，避免异步 `pop()` 弹掉新页面；设备引导与断开确认均防重复触发。后台期间接收请求提示暂缓，防止与配对模态叠加。

发现名称不作为 TLS 验证后的身份名称；已扫描对端名称来自真实配对响应。入站会话及历史设备有明确引用，UI 不再通过 ID 字符串前缀决定授权。

## 断开与任务保护

操作卡片实时读取所选连接的非终态任务。存在任务时先确认“中断传输并断开”。取消确认不撤销会话；确认后仅撤销选定入站 session 或匹配的出站客户端，其他连接继续保留。

入站任务使用 SQL ownership；出站任务在应用运行时登记 connection ref。断开撤销任务访问令牌，不执行 `revokeAll`，不删除恢复/完成秘密、manifest、committed 块、checkpoint 或已导出记录。READY/TRANSFERRING 状态转为 INTERRUPTED；尚未接受且没有合法 INTERRUPTED 边的 proposal 转为 FAILED。PAUSED/INTERRUPTED 保持可恢复状态；VERIFYING/EXPORTING 是本地完成阶段，继续完成，不把它们强行改成网络中断。各网络循环会及时识别 INTERRUPTED。

本次没有实现或宣称自动续传。重启后出站运行时引用不保留，因为当前 QR 会话本就不跨进程；持久化恢复能力仍依照原协议和任务恢复实现，不能把重新发送新任务当恢复验收。

## 自动化覆盖

| 要求 | 本次证据 | 范围限制 |
|---|---|---|
| AT-01 本机 QR | 应用测试确认真实载荷相同、打开不刷新、关闭节点继续运行 | 无相机真机证据 |
| AT-02 扫码成功 | 首页真实 TLS 测试：单扫描器、配对响应名称、返回首页、无高级表单 | 载荷由注入扫描器返回；真实相机归 MT |
| AT-03 取消/拒绝/错误码 | 组件测试：取消安静返回、权限请求后重读、扫描失败/无效码只提示一次 | 平台摄像头停止仍需 MT |
| AT-04 取消后晚到 | 协调器控制 Future 完成顺序：旧成功关闭，不能覆盖新连接；延迟 lease 释放 | 真实系统网络取消需 MT |
| AT-05 重复入口 | 应用测试两次调用首页扫码回调只构建一次、候选双击只有一个引导模态；协调器拒绝重叠连接 | 真实触控与平台快速操作归 MT-05 |
| AT-06 证明过期 | radar 读模型保留 incoming ref；stale card 保留断开按钮且无表单 | 实机静置窗口需 MT-06 |
| AT-07 选定断开 | 实际 TLS 两个入站会话：关闭卡片保持授权，断开一个后另一个保留 | 多方向/真机组合需 MT |
| AT-08 活动任务 | 应用测试活动任务确认：重复触发只有一个确认框，取消保留任务和授权，确认后中断；selected task 测试保留恢复/完成秘密和 committed/export 记录 | 真实文件传输期间关闭卡片需 MT-08 |
| AT-09 后台/销毁 | PeerSession 销毁晚到结果、协调器销毁/取消回归；已有应用 BLE 后台回归保留 | Android 相机与系统网络后台行为需 MT-05 |
| AT-10 发现引导 | 应用测试 BLE 候选只出现扫码引导，不授予授权；认证后采用真实名称 | BLE/mDNS 双机发现需 MT-02 |
| AT-11 路由与可访问性 | 旧路由清理；高级页关闭后的晚到结果不弹别的路由；200% 字体/长名称无溢出 | Windows Esc/焦点、屏幕阅读器需设备验证 |
| AT-12 Windows 图片 | 图片选择取消安静返回、无效图错误一次、无旧表单 | 真实系统选择器/有效图片需 MT-10 |
| AT-13 高级连接 | 组件成功/失败/关闭晚到；真实 TLS 应用收发经高级入口且回首页 | 系统导图与手工操作需 MT-11 |
| AT-14 传输回归 | 保留实际 TLS UI 发送、拉取接收、推送接收并核对文件 SHA-256；任务/进度全量回归 | 双向多文件真机和恢复仍未执行 |

混合连接页的组件规格已迁移到独立 surface、coordinator、task lifecycle 和应用测试；没有用假成功客户端替换原真实 TLS 文件闭环。旧页面已删除，其专有表单测试随规格替换；任务详情、错误码和进度测试继续保留。全量测试数量采用本次真实执行输出。

## 本地验证

环境：Linux 执行工作区；Flutter 3.47.5 / Dart 3.13.4，符合 `.fvmrc`；未升级依赖、锁文件保持不变。命令在仓库根目录执行。

| 检查 | 结果 |
|---|---|
| `flutter pub get` | 通过 |
| `dart format --output=none --set-exit-if-changed .` | 242 文件，0 改动，通过 |
| `flutter analyze` | No issues found，通过 |
| `flutter test` | 1432 项通过 |
| Python tooling/s0 回归 | 24 项通过；本地 socket 用例在允许本地网络的执行环境运行 |
| `python3 tooling/checks/check_links.py --strict` | 109 Markdown / 593 链接，无损坏相对链接 |
| `python3 tooling/checks/check_secrets.py` | 已跟踪文件扫描通过 |
| `python3 tooling/checks/check_ci_workflow.py` | 工作流不变量通过 |
| `git diff --check` | 通过 |
| Android debug / Windows release 构建 | 本机未执行：无 Android SDK、Windows runner；由 PR CI 分别验证 |

## 设备验收与剩余限制

MT-01 至 MT-12 全部未执行。本环境没有两台 Android 和 Windows 实机，不能填写“通过”。逐项步骤和标准保留在开发方案第 10 节，可按该矩阵执行并追加设备、系统、网络角色、完整提交 SHA、文件大小及哈希证据。

剩余限制：真实相机初始化/权限生命周期、Windows 系统选择器与键盘焦点、系统网络 join/release、关闭卡片期间传输、双向多文件与中断恢复未取得本次硬件证据。PAKE、正式签名、热点全链路及大文件恢复也不在本次完成范围。当前发布保持 Preview；本次分支代码尚未合并或发版。
