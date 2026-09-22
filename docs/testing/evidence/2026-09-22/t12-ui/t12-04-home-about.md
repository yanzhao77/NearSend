# T12-04 首页与关于页证据

日期：2026-09-22

## 已执行

- `flutter test --no-pub test/features/home/home_page_test.dart test/features/about/about_page_test.dart`
- `flutter test --no-pub test/app/app_test.dart`
- `dart format --output=none --set-exit-if-changed`（本次修改文件）
- `dart analyze`（本次修改涉及 Dart 文件）

结果：页面定向测试通过；应用级连接、发送、接收测试通过。

## 已实现

- 首页发送/接收使用同等主操作卡片。
- 继续任务仅由真实 `TaskCatalogController` 的可恢复状态驱动。
- 首页明确说明不依赖互联网但需要本地 Wi-Fi。
- 关于页保留版本、Git、协议、schema、构建渠道，并明确未知/未验证状态。

## 未执行

- Windows、iOS 真机截图和键盘/系统返回验证：当前环境没有对应目标设备。
- `flutter analyze`：本机 Dart 3.12.2 不满足项目 `sdk: ^3.13.4`，Flutter 在依赖解析阶段拒绝执行；未修改约束绕过。
