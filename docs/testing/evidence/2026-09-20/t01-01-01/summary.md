# T01-01 运行汇总

- 运行 ID：`t01-01-01`
- 任务：[T01-01 Flutter 工程基线](../../../../tasks/T01-01.md)
- 日期：2026-09-20
- 基线提交：`ba7c1825043d4e830daf0b62d05789438f8139d0`
- 分支：`feat/t01-01-flutter-baseline`
- 主机：Windows 10 22H2 (10.0.19045.6466)
- **结论：在下列具体环境与设备上，T01-01 的自动化门槛与两端真机/实机验证全部通过。**

> 本文件只陈述本次实际执行并留证的结果。它不代表传输、配对、发现、存储、恢复等业务能力，
> 那些能力在本次改动中**并未实现**。

## 1. 验收条件逐项核对

| 验收条件 | 结果 | 证据 |
| --- | --- | --- |
| Android 构建成功 | 通过 | `build-android-debug.log`、`build-android-release.log`；debug 150,506,612 B、release 44,939,724 B |
| Windows 构建成功 | 通过 | `build-windows-release.log`；`nearsend.exe` 90,624 B |
| Android 可安装并启动 | 通过 | [android-run.md](android-run.md)；Xiaomi 25102RKBEC / Android 17 (API 37) |
| Windows 可运行 | 通过 | [windows-run.md](windows-run.md)；窗口标题 `NearSend` |
| 两端显示版本、Git commit、协议版本、schema 版本 | 通过 | `android-ui-about.xml`、`windows-about.png` |
| 没有业务逻辑放入平台目录 | 通过 | [platform-directory-audit.md](platform-directory-audit.md) |
| `dart format` / `flutter analyze` / `flutter test` 通过 | 通过 | `check-script.log`；analyze `No issues found`；test 29/29 |
| `pubspec.lock` 进入版本控制 | 通过 | `.gitignore` 增加 `!pubspec.lock`；`git check-ignore -q` 退出码 1 |

## 2. 产物与摘要（`artifacts-sha256.json`）

| 产物 | 模式 | 字节 | SHA-256 |
| --- | --- | --- | --- |
| `build/app/outputs/flutter-apk/app-debug.apk` | debug | 150,506,612 | `C51EEAF6384F524A1108C5AA26EB851C19DDE5C9F96884129ADD188FE6F5E35A` |
| `build/app/outputs/flutter-apk/app-release.apk` | release | 44,939,724 | `FAB26F56FC9590DE4F6A604FF846DDED9AB15B1B454DF28A594E13D55479D904` |
| `build/windows/x64/runner/Release/nearsend.exe` | release | 90,624 | `AAFD7E5771BCE57086886A9E1A0004FA18F3D66A0CC005A302183D335758B2EC` |

三者都由同一次构建流程注入 `NS_GIT_SHA=ba7c182…`、`NS_GIT_DIRTY=true`、`NS_BUILD_CHANNEL`，
因此可以回溯到确切的源码提交（技术方案 §17.3）。

## 3. 自动化检查

```text
dart format --output=none --set-exit-if-changed .   → 通过（无改动）
flutter analyze                                     → No issues found!
flutter test                                        → 29 个测试全部通过
tooling/s0: python -m unittest -v test_probes       → 24 个测试全部通过
```

测试内容覆盖：`pubspec.yaml` 与 `kAppVersion` 一致性、协议/schema 常量与「未冻结/未创建」诚实标注、
Git SHA 不伪造、`UI_UX_SPEC` §5 色彩与间距/圆角/字号/动效 Token 逐值一致、
六组前景/背景组合达到 WCAG AA 对比度、按钮主题满足 48dp 触控目标、
减少动效偏好生效、首页主操作禁用且标注未实现、版本信息页四类信息渲染。

## 4. 环境搭建记录（本次新增，仓库外）

T01-01 开始时本机**没有** Flutter/Dart SDK，`C:\tools\Android` 为空。本次安装并留证：

| 组件 | 版本 | 校验 |
| --- | --- | --- |
| Flutter SDK | 3.47.5 stable（Dart 3.13.4） | zip 1,933,437,428 B，SHA-256 `0ccd71931f49c2fbe394b1eeb6d79af3d624058a043ea0d03d34160581624fb8` |
| Android cmdline-tools | build 16111833 | zip 154,957,218 B，SHA-256 `e5885e2e59038c0778a85fc19f01de7ce7c567c105553f7617b936b1e0e87b2b` |
| Android platform | android-36 | 通过 `android sdk install` |
| Android build-tools | 36.0.0 | 同上 |
| Android NDK | 28.2.13676358 (r28c) | Flutter 3.47.5 的默认 `ndkVersion` |
| platform-tools | 37.0.1 | 由 `sdkmanager` 安装 |

完整事实见 [environment.json](environment.json) 与 `flutter-doctor.log`（`flutter doctor -v` 报告 `No issues found!`）。

### 环境相关的两个坑（已解决，需在 CI 中复现）

1. **cmdline-tools 16111833 的 `sdkmanager` 已废弃且会崩溃。** 它在完成实际工作后以
   `0xC0000409 (STATUS_STACK_BUFFER_OVERRUN)` 退出，导致 Gradle/AGP 把它当作失败。
   替代方式是 `android sdk install <pkg>`。
2. **Gradle 不读取 Windows 的 WinINET 代理。** 本机只能经 `127.0.0.1:6789` 出网，
   已在 `%USERPROFILE%\.gradle\gradle.properties` 中声明 `systemProp.http(s).proxyHost/Port`
   （机器本地配置，不入库）。另外该代理会拦截证书吊销检查，`curl` 需要 `--ssl-revoke-best-effort`。

## 5. 附带发现：S0 参考探针在 Windows 上不可复现（已修复）

首次在本机运行 `tooling/s0` 时，台账记载的「24项通过」**不能复现**：实际只运行 21 项，其中 1 项失败。
根因是探针用 `Path.read_text()` 而不指定编码，在 `cp936` 机器上把 UTF-8 的协议向量按 GBK 解码，
规范化字节串因此与固定向量不一致；`make_vectors.py` 写文件时同样依赖 locale。
已为这些文本 I/O 显式指定 UTF-8，并验证在 cp936 机器上重新生成向量得到**字节相同**的文件
（SHA-256 `D66786736789C9A1568F63ADBBFE5A4048E90667260EFFA97A96DD43FDB96CA0` 前后一致），
24 项恢复全部通过。完整过程、原始失败日志与影响见
[s0-probe-baseline-on-windows.md](s0-probe-baseline-on-windows.md)。

**本次未删除任何失败证据；修复后的日志与修复前的日志并列保留。**

## 6. 已知限制与未执行项

| 限制 | 说明 |
| --- | --- |
| release APK 未正式签名 | 无 `android/key.properties`，Flutter 使用调试签名；**不可分发**。签名属 T10。 |
| 未验证 Windows 11 | 本机为 Windows 10 22H2；技术方案要求 Windows 11 优先验证，本结论不覆盖 Win11。 |
| 未验证 iOS | 本机无 macOS/Xcode；iOS 仅生成了工程目录，未构建。B06/T09 仍阻塞。 |
| 未验证深色模式/动态字体/屏幕阅读器/大列表性能 | 属后续 UI 任务验收项。 |
| 未冻结 minSdk / Windows 最低版本 / iOS 最低版本 / TLS 引擎 / SQLite 插件 | 见 `ADR-0001` 的「未决」小节。 |
| 未做任何网络与传输验证 | 业务能力尚未实现。 |
| Windows 端无结构化元素转储 | Flutter Windows 默认不向 UI Automation 暴露控件树。 |
