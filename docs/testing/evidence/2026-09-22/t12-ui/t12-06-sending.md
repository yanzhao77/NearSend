# T12-06 发送流程页面证据

日期：2026-09-22
分支：`feat/ui-baseline`

## 已执行

- `flutter test --no-pub test/features/transfer/send_page_test.dart test/app/widgets/near_send_widgets_test.dart`：18 项通过。
- `dart analyze test/features/transfer/send_page_test.dart`：无问题。
- `dart analyze lib/app/widgets/near_send_widgets.dart lib/features/transfer/presentation/send_page.dart`：无问题。
- `dart format`：本次修改文件无格式变更。

## 已实现

- 文件选择、来源提示、五阶段进度和发送失败均使用共享组件。
- 通过 `ListView.builder` 保持大文件清单的虚拟化边界；不再使用会在动态字体下溢出的固定行高。
- 长文件名中间省略并保留扩展名，完整名称保留在 Tooltip。
- 准备、等待对方、传输、等待校验/保存和失败状态使用不同文案；速度只在发送阶段出现。
- 文件来源平台差异保持：文档平台提供选择器，路径平台提供路径输入。

## 未执行

- `flutter analyze`：当前 Dart 3.12.2 不满足 `pubspec.yaml` 的 `^3.13.4`，Flutter 在依赖解析阶段拒绝执行。
- Windows/iOS 真机文件选择、动态字体 200% 和一万文件性能：当前环境没有对应目标设备，未伪造结果。

## 人工重点复核

大文件流式准备、真实哈希进度、长文件名、一万项列表滚动和 Android SAF/Windows 路径句柄。
