# T12-09 平台适配证据

日期：2026-09-22  
分支：`feat/ui-baseline`

## 已实现

- Android `MainActivity` 新增 `defaultReceiveLocation` 和 `measureFreeSpace` 通道方法。
- Android 默认接收位置是应用私有 `filesDir/received`，可由现有路径导出器写入；`StatFs.availableBytes` 作为可用空间来源。
- Android 对 `content://` 和异常路径返回未知空间，不将不可测量结果折算为零或充足。
- Flutter 主入口在 Android 装配 `MethodChannelAndroidStorageGateway`；Windows、iOS 没有可验证网关时保留未知能力。
- 目录选择由 `PlatformStorageGateway.supportsDirectorySelection` 控制。Android SAF tree URI 选择仍关闭，因为当前 `ExportSink` 只支持普通路径，开放它会产生无法导出的假能力。
- 桌面壳增加 `ReadingOrderTraversalPolicy`；Windows 原生窗口设置最小跟踪尺寸 `900×640`。
- iOS `Info.plist` 增加本地网络使用说明，文案明确不通过互联网中转。

## 已执行

- `flutter --version`：Flutter `3.44.8`，Dart `3.12.2`。
- `flutter devices`：发现 Android `M2104K10AC`（Android 13/API 33）、macOS desktop、Chrome；未发现 Windows 或 iOS 目标。
- `dart format lib/platform/platform_storage_gateway.dart lib/main.dart lib/app/presentation/app_shell.dart lib/features/settings/presentation/settings_page.dart lib/app/app.dart test/platform/platform_storage_gateway_test.dart test/app/presentation/app_shell_test.dart`：完成格式化。
- `git diff --check`：通过。

## 未执行或阻塞

- `flutter pub get`：阻塞。当前 Dart `3.12.2` 不满足 `pubspec.yaml` 的 `^3.13.4`，未降低 SDK 约束绕过。
- `flutter test`、`flutter analyze`、`flutter build apk --debug`：依赖解析被同一 SDK 版本阻塞。
- Android 真机空间测量、默认目录实际导出和截图：当前轮次未执行，不能把通道代码当作真机证据。
- Windows 原生构建、900×640/1280×720/宽屏截图、文件入口和键盘探针：当前环境无 Windows 目标。
- iOS 安全作用域目录、可用空间、后台生命周期、`flutter build ios --no-codesign` 和真机截图：当前环境无 Xcode/iOS 目标。

## 人工重点复核

- Android 应用私有默认目录与导出结果是否符合产品预期。
- Android SAF tree URI 导出器实现后，才能重新开放目录选择入口。
- Windows 最小窗口尺寸在 DPI 缩放下的实际客户区结果。
- iOS 本地网络权限弹窗、安全作用域资源和前后台恢复。
- 所有未验证平台不能使用“通过”或成功截图作为验收结论。
