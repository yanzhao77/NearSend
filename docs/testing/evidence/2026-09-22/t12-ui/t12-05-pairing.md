# T12-05 配对与连接页证据

日期：2026-09-22
分支：`feat/ui-baseline`

## 已执行

- `flutter test --no-pub test/features/transfer/transfer_pages_test.dart`：24 项通过。
- `flutter test --no-pub test/features/transfer/send_page_test.dart test/app/widgets/near_send_widgets_test.dart`：15 项通过。
- `dart analyze lib/app/app.dart lib/features/transfer/presentation/send_page.dart lib/features/transfer/presentation/transfer_pages.dart lib/app/widgets/near_send_widgets.dart`：无问题。
- `dart format`：本次修改文件无格式变更。

## 已实现

- 连接页区分节点启动、未发布、连接中、已连接和失败状态。
- 展示本机设备名/平台、对端设备名/平台、地址和指纹；协议未提供的字段保持未知。
- 指纹验证前显示“待验证”，连接成功后才显示“已验证”。
- TLS pin 不匹配继续阻断连接，并展示对端实际指纹和可执行的重新配对方向。
- 仍使用严格 `PairingPayload.parse`，未引入 QR 依赖、明文降级或全局信任证书。

## 未执行

- `flutter analyze`：当前 Dart 3.12.2 不满足 `pubspec.yaml` 的 `^3.13.4`，Flutter 在依赖解析阶段拒绝执行。
- Windows/iOS 真机连接、键盘和系统生命周期验证：当前环境没有对应目标设备。
- 本任务不伪造平台截图或构建结果。

## 人工重点复核

证书指纹、一次性令牌、指纹变化阻断和重新配对路径。
