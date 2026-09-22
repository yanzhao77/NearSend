# T12-07 接收流程与空间预检证据

日期：2026-09-22  
分支：`feat/ui-baseline`

## 已实现

- 接收列表、推送到本机的待确认列表、保存位置输入和平台目录选择使用共享 UI 组件。
- 主操作统一为“接收并保存”；保存位置以不透明引用传递，不把 SAF URI、安全作用域资源或 Windows 句柄当普通路径。
- 空间预检显示暂存、数据库和导出峰值的逐卷明细。
- `sufficient`、`insufficient`、`unknown` 使用不同语义；未知空间不显示绿色通过，且必须由用户明确确认风险。
- 已知空间不足不提供可执行接受按钮，并说明清理或更换位置的下一步。
- 多个推送 offer 的预检结果按 `transferId` 区分，避免显示其他任务的空间结论。
- 未提供设备名称、平台或地址的协议字段保持诚实空态，不猜测对端身份。

## 已执行

- `flutter test --no-pub test/features/transfer/receive_page_test.dart test/features/transfer/receive_confirmation_page_test.dart test/features/transfer/server_receiving_flow_test.dart`：16 项通过。
- `git diff --check`：通过。

## 未执行

- `flutter test --no-pub test/app/app_test.dart`：先因 Flutter 构建缓存缺失 `build/native_assets/macos/native_assets.json` 失败；随后执行 `flutter clean`，但当前 Flutter 3.44.8 / Dart 3.12.2 无法满足 `pubspec.yaml` 的 Dart `^3.13.4`，`flutter pub get` 在依赖解析阶段阻塞，因此未能恢复应用级测试。
- `flutter analyze`：同一 SDK 约束阻塞。
- Android 真机、Windows 和 iOS 的空间/目录选择能力：当前环境没有完整目标环境，未伪造结果。

## 人工重点复核

空间预检和实际接受之间的存储变化、平台 URI/句柄生命周期、空间不足与未知空间确认、取消后已导出文件保留。
