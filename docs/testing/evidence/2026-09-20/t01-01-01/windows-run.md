# T01-01 Windows 构建与运行验证

- 运行 ID：`t01-01-01`
- 日期：2026-09-20
- 结论：**通过**（Windows 10 22H2 上）
- 原始资料：`windows-app.png`（首页）、`windows-about.png`（版本信息页）、`build-windows-release.log`、`artifacts-sha256.json`

## 1. 环境

| 项 | 值 |
| --- | --- |
| 系统 | Microsoft Windows 10 专业版，22H2，10.0.19045.6466，64 位 |
| 机型 | HP Pavilion Power Laptop 15-cb0xx，Intel i7-7700HQ，15.9 GiB RAM |
| 工具链 | Flutter 3.47.5 / Dart 3.13.4 |
| 原生工具链 | Visual Studio Community 2022 17.14.37614.0（含 VC++ x86/x64 工具集），Windows 10 SDK 10.0.26100.0 |
| 产物 | `build/windows/x64/runner/Release/nearsend.exe`，90,624 字节，SHA-256 `AAFD7E5771BCE57086886A9E1A0004FA18F3D66A0CC005A302183D335758B2EC` |
| 构建提交 | `10215137453b5be41cf61a286623b63f0a3833f4`（`gitDirty=false`） |

`Release` 目录组成（应用需要与 DLL、`data/` 同目录运行）：

```text
nearsend.exe          90,624 bytes
flutter_windows.dll   21,274,112 bytes
data/                 Flutter 资源与 AOT 产物
```

## 2. 操作步骤与结果

| # | 命令 / 操作 | 预期 | 实际 | 结果 |
| --- | --- | --- | --- | --- |
| 1 | `flutter build windows --release` | 产出可执行文件 | `✓ Built build\windows\x64\runner\Release\nearsend.exe` | 通过 |
| 2 | 直接启动 `nearsend.exe` | 进程存活、窗口标题正确 | pid 12152，`MainWindowTitle = NearSend` | 通过 |
| 3 | 窗口首帧渲染 | 显示壳应用内容 | 见 `windows-app.png` | 通过 |
| 4 | 将窗口置于前台后按 `Tab` 再按 `Enter` | 键盘可聚焦并激活「版本与诊断」入口 | 跳转到版本信息页，见 `windows-about.png` | 通过 |
| 5 | 关闭窗口 | 进程正常退出 | 进程结束，无残留 | 通过 |

窗口标题 `NearSend` 证明 `windows/runner/main.cpp` 的窗口标题与 `Runner.rc` 的产品名改动生效。

## 3. 版本信息页（Windows 端，截图读取）

`windows-about.png` 中可见：

```text
版本与诊断
NearSend
应用版本          0.1.0+1
Git 提交          ba7c182（构建时工作区有未提交改动）
协议版本          1.0 · 1.0-draft1（草案，未冻结）
数据库 schema 版本  1（已声明，数据库尚未创建）
构建渠道          internal
关于以上数值的含义
• 协议版本为草案，尚未冻结；协议能力协商与状态模型由 T02-02 实现。
• 数据库 schema 版本目前只有声明值，本版本未创建任何 SQLite 数据库；真实 schema、迁移与故障测试由 T04-01 实现。
• Git 提交在构建时通过 --dart-define 注入；未注入时显示 unknown，不显示推测值。
```

即三个平台目录改动（Android label、iOS CFBundleDisplayName、Windows 窗口标题/产品名）之外，
两端运行的是**同一份 Dart 壳应用**，版本信息由同一处常量与同一次构建注入产生。

## 4. 除上述之外还验证到的结论

`Tab` → `Enter` 能激活应用栏按钮，说明 `UI_UX_SPEC` §8 要求的桌面键盘焦点路径在 Windows 上可用。
本次没有进一步验证完整 Tab 顺序、`Escape` 返回、上下文菜单与焦点可见样式。

## 5. 已知限制

1. **只验证了 Windows 10 22H2。** 技术方案 §1.3 要求 Windows 11 优先验证，
   本机不具备 Windows 11 环境，因此**不能**据此声明 Windows 11 兼容性。
2. 未打包 MSIX，未做签名安装包（T10）。
3. 未验证防火墙、监听端口、离线组网与任何网络相关行为（业务能力尚未实现，且属 B01/B08/T07）。
4. 未验证 Windows 深色模式、200% 动态字体、屏幕阅读器语义与窗口缩放无溢出。
5. 自动化过程中一次误点窗口关闭按钮导致应用退出；这是人工自动化脚本的坐标错误，
   不是应用缺陷。此后改用键盘导航完成验证，未再出现异常退出。
6. Flutter Windows 默认不向 UI Automation 暴露控件树（仅暴露 `FLUTTERVIEW` 画布），
   因此 Windows 端没有 `uiautomator` 等价的结构化元素转储，验证依据是截图与键盘交互。
