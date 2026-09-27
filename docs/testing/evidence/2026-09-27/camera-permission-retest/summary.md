# Android 扫码相机授权复测

日期：2026-09-27 22:37（本机时间）

应用代码基线：`3c30f5dce246949a7de6e0dfedf9a942edfcc792`

设备：Xiaomi M2104K10AC（chopin），Android 13 / API 33，arm64-v8a
APK：本机 v0.1.12 / versionCode 18 release 验收构建，SHA-256：
`947AFBEAEC3086A9BD1CE5FC64A78F0149F15D47C18E348A26574693BB4F82E9`

## 结果

- 系统包状态报告 `android.permission.CAMERA: granted=true`；AppOps 为 `CAMERA: allow`。
- 从首页点击“扫一扫连接设备”后，原有 Dart 权限预检通过，进入“扫描配对码”页面。
- `mobile_scanner` 相机预览正常显示；日志中没有 `MissingPluginException`、Flutter 未处理异常或权限拒绝。
- 未扫描 Windows 二维码，未执行设备配对或文件传输；本记录只验证相机权限与预览。

## 根因

本机此前有一份未跟踪的 `GeneratedPluginRegistrant.java`，其中包含 release 构建不存在的
`integration_test` 插件条目。release 编译因此失败。首次排障构建时整份注册文件被暂时移出，
导致 APK 没有注册任何生成式 Flutter 插件；手机日志随后明确报出
`MissingPluginException`，包括 `mobile_scanner` 的 `state` 和扫码事件通道，界面把它显示为
“系统未能确认相机权限状态”。

保留 `mobile_scanner` 注册、只移除过期的 `integration_test` 注册后，release APK 成功构建。
随后在没有修改权限网关或 Android 权限设置的情况下，原有权限检查通过且相机预览正常。
因此本轮复现的拦截来自本机生成插件注册文件污染，不是 Android 的“仅在使用中允许”授权未生效。

## 检查

- `flutter test test/platform/platform_permission_gateway_test.dart`：3 项通过。
- `git diff --check`：通过。
- `flutter build apk --release --no-pub --build-name 0.1.12 --build-number 18`，并注入基线 SHA 与 preview channel：通过。
- `adb install -r build/app/outputs/flutter-apk/app-release.apk`：成功；没有卸载应用或清除数据。
- 在原权限网关代码下通过 ADB 打开扫码页；截图确认实时预览，AppOps 为 `allow`，定向 logcat 未见插件缺失或权限错误。

## 限制与复核

- 本机 release 验收包使用当前项目配置的 debug signing；它不是重新下载的 GitHub Release APK。
- Flutter 测试可能重写忽略的 Android 插件注册生成文件；在本机 Android release 构建前应检查它与当前 build variant 的插件集合一致。不要将生成文件纳入版本控制。
- 相机启动正常不代表二维码配对或 Android ↔ Windows 文件传输已通过。
