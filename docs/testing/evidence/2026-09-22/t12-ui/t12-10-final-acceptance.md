# T12-10 UI 最终验收证据

日期：2026-09-22  
分支：`feat/ui-baseline`

## 自动化覆盖

- Design Token 测试覆盖 Light/Dark `ColorScheme`、七级排版、间距/圆角/尺寸、WCAG AA 对比度、按钮/输入/对话框/进度主题。
- 共享组件测试覆盖按钮 loading、Banner 语义、文件名中间省略、五阶段进度、空间 unknown 非成功、Dark + 200% 文本。
- 新增 `test/app/ui_acceptance_test.dart`，覆盖 320px 窄宽度、200% 动态字体、长文件名、长错误文案、状态语义标签和阶段语义标签。
- 接收确认测试覆盖 sufficient、insufficient、unknown、无预检；任务详情测试覆盖真实 SQLite 状态、committed 块进度、导出记录、暂停/可恢复；传输页测试覆盖准备、连接、传输、校验、保存、暂停、失败和未知总量。
- 连接测试覆盖严格载荷解析、指纹展示和连接状态；首页/关于页测试覆盖本地 Wi-Fi 说明、真实工程状态和诊断信息。

## 已执行

- `flutter --version`：Flutter `3.44.8`，Dart `3.12.2`。
- `flutter devices`：Android `M2104K10AC`（Android 13/API 33）、macOS desktop、Chrome；没有 Windows/iOS 目标。
- `flutter pub get`：失败，仓库要求 Dart `^3.13.4`，当前为 `3.12.2`；未修改 SDK 约束。
- `flutter test --no-pub ...`：当前环境因依赖未解析而无法启动；此前 T12-07 的定向测试在 SDK 阻塞前通过 16 项，T12-08 新增测试尚未运行。
- `dart format`：限定 T12-09/T12-10 文件完成格式化；formatter 读取 `analysis_options.yaml` 时提示 `flutter_lints` 未解析，但未引入无关格式改动。
- `git diff --check`：通过。

## 未执行或阻塞

- `flutter analyze`、完整 `flutter test`、`flutter build apk --debug`：受 Dart SDK 版本和依赖解析阻塞。
- Android 真机截图、动态系统字体、键盘/屏幕阅读器和实际空间测量：本轮未执行，不能用 widget 测试代替。
- Windows `900×640`、`1280×720`、宽屏构建/截图/键盘操作：没有 Windows 环境。
- iOS `flutter build ios --no-codesign`、安全作用域目录、后台生命周期、权限弹窗和真机截图：没有 Xcode/iOS 环境。

## 结论

代码级 UI 验收覆盖已补齐，平台级最终验收不能标记为通过。T12-10 保持阻塞，直到至少恢复 Dart `3.13.4+` 的 Flutter 工具链，并取得 Android 真机、Windows 和 iOS 的实际构建/截图/交互证据。

## 人工重点复核

- 安全配对与 TLS 指纹阻断。
- 文件写入、保存位置、committed checkpoint、SQLite 迁移和导出记录。
- 空间不足/未知、清理范围以及取消后已导出文件保留。
- Android SAF tree URI 导出器完成前不得开放目录选择。
- Windows/iOS 未验证项不得在发布说明中标为通过。
