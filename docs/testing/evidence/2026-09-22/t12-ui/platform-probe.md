# T12 UI 平台能力 S0 探针

日期：2026-09-22
分支：`feat/ui-baseline`

## 环境

本机 `flutter devices` 发现：

- Android 真机 `25102RKBEC`，Android 17/API 37
- macOS desktop
- Chrome web

未发现 Windows 或 iOS 目标设备。当前 Flutter 为 3.44.8，Dart 为 3.12.2；仓库 `pubspec.yaml` 要求 Dart `^3.13.4`，所以基线 `flutter analyze` 和 `flutter test` 在依赖解析阶段被阻塞。

## 能力结论

| 能力 | Android | Windows | iOS | 结论 |
| --- | --- | --- | --- | --- |
| 应用私有目录 | 已有 `applicationDirectory` SAF 通道 | 现有 `LOCALAPPDATA/NearSend` 解析 | 未验证 | 可沿用现有目录适配边界，iOS 需原生验证 |
| 文件选择 | 已有 SAF 文档选择和 URI 读写 | 现有路径输入，系统选择器待验证 | 未验证 | 不把 URI 转成普通路径 |
| 可用空间 | 未有生产通道 | 未验证 | 未验证 | 首版 UI 必须支持 `unknown`，不能显示假通过 |
| 默认接收目录 | 未有持久化设置 | 未有持久化设置 | 未验证 | T12-03 通过非机密 SQLite 设置存储接入 |
| 目录选择 | 未有目录选择通道 | 未验证 | 未验证 | 需要单独平台探针后冻结 |
| 设置持久化 | 未有应用设置表 | 未有应用设置表 | 未验证 | 使用 SQLite 非机密设置表；不存令牌/私钥 |
| 后台/生命周期 | NodeSession 已有启动/停止边界 | NodeSession 已有启动/停止边界 | 未验证 | iOS 前后台恢复仍是 T12-09 阻塞项 |

## 决策

1. 先实现跨平台 UI 和 `unknown` 空间状态，不把无法测量的卷标为充足。
2. 设置数据仅包括设备名、默认接收位置和界面偏好；凭证、私钥和恢复密钥不进入设置表。
3. 平台存储能力通过 `lib/platform/` 抽象；页面不得直接判断平台或操作路径。
4. Windows/iOS 的未验证能力在任务卡和最终证据中保持“待平台验证”，不标记为已完成。

## 未执行

- Windows 原生空间、目录选择和键盘焦点实机探针：当前环境无 Windows 设备。
- iOS 安全作用域目录、空间测量、后台生命周期和权限探针：当前环境无 Xcode/iOS 设备。
- Android 真机空间和持久化 URI 权限探针：本轮尚未运行，后续平台任务补充。
