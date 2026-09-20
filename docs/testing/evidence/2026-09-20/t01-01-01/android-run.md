# T01-01 Android 真机安装与启动验证

- 运行 ID：`t01-01-01`
- 日期：2026-09-20
- 结论：**通过**（在下列具体设备与环境上）
- 原始资料：`android-home.png`、`android-about.png`、`android-ui-home.xml`、`android-ui-about.xml`、`build-android-release.log`、`artifacts-sha256.json`

## 1. 设备与环境

| 项 | 值 |
| --- | --- |
| 制造商 / 型号 | Xiaomi / 25102RKBEC |
| 设备代号 | `myron` |
| 系统版本 | Android 17 |
| API 级别 | 37 |
| 构建号 | `OS4.0.0.31.XPMCNXM` |
| ABI | `arm64-v8a` |
| 连接方式 | USB（adb serial `25102RKBEC`，adb id `478ef8a9`） |
| 构建主机 | Windows 10 22H2 (10.0.19045.6466) |
| 构建工具 | Flutter 3.47.5 / Dart 3.13.4 / JDK 21.0.2 / Android SDK platform-36 + build-tools 36.0.0 + NDK 28.2.13676358 |
| 构建提交 | `10215137453b5be41cf61a286623b63f0a3833f4`（`gitDirty=false`） |
| 安装包 | `build/app/outputs/flutter-apk/app-release.apk`，44,939,724 字节，SHA-256 `EF6E025938BCB7137B196EA3A5398D1120951E32D38E79AFF35A75EF6B9A88C5` |

## 2. 操作步骤与结果

| # | 命令 / 操作 | 预期 | 实际 | 结果 |
| --- | --- | --- | --- | --- |
| 1 | `flutter build apk --debug` | 产出 debug APK | `app-debug.apk` 150,506,612 字节 | 通过 |
| 2 | `flutter build apk --release` | 产出 release APK | `app-release.apk` 44,939,724 字节 | 通过 |
| 3 | `adb install -r app-release.apk` | 安装成功 | `Performing Streamed Install` / `Success` | 通过 |
| 4 | `adb shell pm path com.nearsend.app` | 包存在 | `package:/data/app/~~JXWSJt7ypWArC4qAko8B_g==/com.nearsend.app-RvhwyfZadx8qmWX51DI8_w==/base.apk` | 通过 |
| 5 | `adb shell dumpsys package com.nearsend.app` | 版本与 pubspec 一致 | `versionCode=1 minSdk=24 targetSdk=36`，`versionName=0.1.0` | 通过 |
| 6 | `adb shell am start -n com.nearsend.app/.MainActivity` | 启动主界面 | `Starting: Intent { cmp=com.nearsend.app/.MainActivity }` | 通过 |
| 7 | `adb shell pidof com.nearsend.app` | 进程存活 | `1392` | 通过 |
| 8 | `adb shell dumpsys window` | 焦点在本应用 | `mCurrentFocus=Window{... com.nearsend.app/com.nearsend.app.MainActivity}` | 通过 |
| 9 | `adb shell uiautomator dump`（首页） | 首页元素可见 | 见 §3 | 通过 |
| 10 | 点击版本与诊断入口后 dump | 四项版本信息可见 | 见 §4 | 通过 |

## 3. 首页可访问性树（真机读取，非截图推断）

```text
NearSend
版本与诊断信息
当前为 T01-01 工程基线：发送、接收、配对、发现、存储与导出功能均未实现。
无需互联网，设备之间仍需建立本地 Wi-Fi 连接。
发送文件
功能尚未实现（T03-01 / T03-02）
接收文件
功能尚未实现（T03-01 / T03-02）
```

两个主操作按钮均有独立的语义描述，且明确标注未实现——符合
`docs/AGENT_TASK_PLAYBOOK.md` §9 对「不得把静态壳标为完成」的要求。

## 4. 版本信息页真机文本（T01-01 验收项）

```text
版本与诊断
NearSend
应用版本          0.1.0+1
Git 提交          1021513
协议版本          1.0 · 1.0-draft1（草案，未冻结）
数据库 schema 版本  1（已声明，数据库尚未创建）
构建渠道          internal
关于以上数值的含义
• 协议版本为草案，尚未冻结；协议能力协商与状态模型由 T02-02 实现。
• 数据库 schema 版本目前只有声明值，本版本未创建任何 SQLite 数据库；真实 schema、迁移与故障测试由 T04-01 实现。
• Git 提交在构建时通过 --dart-define 注入；未注入时显示 unknown，不显示推测值。
```

这证明 T01-01 的验收项「应用能显示版本、Git commit、协议版本和数据库 schema 版本」
在**真实 Android 设备**上成立，且 Git 提交确实由构建期注入、与构建提交 `1021513` 一致。

`Git 提交` 一行**没有**「构建时工作区有未提交改动」后缀，说明该产物可回溯到干净的提交，
而不是在工作区带改动的情况下构建的。

## 4.1 UI Baseline 1.0 并入后的复验

`docs/ui/STYLE_GUIDE.md`（UI Baseline 1.0）并入 `master` 后，设计 Token 被重写
（卡片圆角 12→16、按钮圆角 10→12、新增独立画布色等）。改动后已重新构建、重新安装并再次采集：
`android-home.png`、`android-about.png`、`android-ui-*.xml` 均为**并入 UI Baseline 1.0 之后**的产物。
截图中可直接观察到页面使用带色调的画布背景，卡片为 16dp 圆角并带 1dp 边框，而不是纯白页面。

## 5. 已知限制

1. **release APK 使用调试签名。** 仓库没有 `android/key.properties`，Flutter 因此退回调试签名。
   该 APK **不可用于分发**，仅用于本次真机安装验证。正式签名属于 T10。
2. 本机为 Windows 10 22H2；**没有在 Windows 11 上做任何验证**。
3. 只验证了「安装 + 启动 + 显示壳信息」。没有验证传输、配对、发现、存储、恢复等任何业务能力
   （这些尚未实现）。
4. 未验证深色模式、动态字体、屏幕阅读器语义与 10,000 项列表性能；这些属于后续 UI 任务的验收项。
5. Flutter 语义树在 Android 上通过 `uiautomator` 可读；Windows 上 Flutter 默认不向 UI Automation
   暴露控件（只暴露 `FLUTTERVIEW` 画布），因此 Windows 端的元素级验证改用键盘导航与截图。
6. 构建期出现的 `Warning: SDK processing. This version only understands SDK XML versions up to 3 but an
   SDK XML file of version 4 was encountered` 属于 AGP 与 cmdline-tools 版本发布时间差，未影响构建结果。
