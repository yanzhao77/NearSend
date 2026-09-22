# T12-08 任务详情、传输详情与结果证据

日期：2026-09-22  
分支：`feat/ui-baseline`

## 已实现

- 任务详情从本地 SQLite 读取任务状态、文件状态、committed 块字节和导出记录，不生成演示任务或演示进度。
- 阶段固定为准备、连接、传输、校验、保存；终态 `completed` 将五个阶段全部标记为完成。
- 可恢复、暂停、连接中断、部分失败、任务失败、校验和保存阶段使用不同语义横幅。
- 文件行显示真实文件名、大小、committed 进度和保存/失败状态；保存记录只在导出结果为 `saved` 时显示成功语义。
- 取消确认明确说明已导出的用户文件不会删除，以及未完成恢复数据的影响。
- 暂停、继续、取消、重连和仅重试失败项由可选真实回调驱动；未接入的协议能力不会渲染假按钮。

## 已执行

- `dart format lib/app/application/task_catalog_controller.dart lib/app/widgets/near_send_widgets.dart lib/features/tasks/presentation/task_overview_page.dart lib/features/tasks/presentation/task_detail_page.dart lib/app/app.dart test/app/application/task_catalog_controller_test.dart test/features/tasks/task_detail_page_test.dart`：完成格式化。
- `git diff --check`：通过。

## 未执行

- Flutter widget/SQLite 测试：`flutter clean` 后本机 Flutter 3.44.8 / Dart 3.12.2 无法满足仓库要求的 Dart `^3.13.4`，`flutter pub get` 在依赖解析阶段阻塞；未降低 SDK 约束绕过。
- `flutter analyze`：同一 SDK 约束阻塞。
- Windows/iOS 真机和屏幕阅读器验证：当前环境无目标平台，未伪造结果。

## 人工重点复核

committed 块与导出记录的对应关系、任务状态迁移、取消后的恢复数据清理、完整性失败和仅重试失败项的协议出边。
