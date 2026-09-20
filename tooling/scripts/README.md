# NearSend 构建与检查脚本

本目录的脚本让每个任务都能用同一组命令复现「格式化 → 静态分析 → 测试 → 构建」，
并把 Git 提交注入产物，使安装包可以追溯到确切的源码版本（技术方案 V2.1 §17.3）。

`.github/workflows/ci.yml` 调用的是**同一套脚本与检查**，因此本地通过意味着 CI 也会通过，
不存在两套会逐渐分叉的规则。

## 前置条件

- 仓库根目录为当前 Flutter 工程（`pubspec.yaml` 与 `.git` 同层）。
- `flutter` 与 `dart` 在 `PATH` 中。
- Windows 构建需要 Visual Studio 2022 的「使用 C++ 的桌面开发」工作负载。
- Android 构建需要 Android SDK；`ANDROID_HOME` 指向 SDK 根目录。
- 仓库级检查（链接、敏感信息、CI 不变量）需要 `python3` 或 `python`；缺失时会明确打印 SKIPPED。

脚本本身不安装工具链，也不修改机器配置。CI 中的 Flutter 安装由
[`tooling/ci/install_flutter.sh`](../ci/install_flutter.sh) 完成（固定版本 + 校验 SHA-256）。

## 调用方式

脚本使用 `#Requires -Version 5.1`，在 Windows PowerShell 5.1 与 PowerShell 7+ 上都能运行。
下面的示例统一写 `pwsh`；如果机器上只有 Windows 自带的 PowerShell 5.1（没有安装 `pwsh`），
把它替换成 `powershell -NoProfile -ExecutionPolicy Bypass` 即可。

## `check.ps1`

按 `AGENTS.md` §7 的顺序运行必做检查，任一步失败立即以非零码退出并保留原始输出：

```text
flutter pub get → dart format 校验 → flutter analyze → flutter test
                → Markdown 相对链接 → 敏感信息 → CI 工作流不变量
```

```powershell
pwsh -File tooling/scripts/check.ps1
pwsh -File tooling/scripts/check.ps1 -SkipTest          # 只做格式化与分析
pwsh -File tooling/scripts/check.ps1 -SkipRepoChecks    # 跳过三项仓库级检查
```

| 参数 | 作用 |
| --- | --- |
| `-SkipFormat` | 跳过 `dart format` 检查 |
| `-SkipAnalyze` | 跳过 `flutter analyze` |
| `-SkipTest` | 跳过 `flutter test` |
| `-SkipRepoChecks` | 跳过 Markdown 链接、敏感信息与 CI 工作流检查 |

## `build.ps1`

构建目标平台，并把 `NS_GIT_SHA`、`NS_GIT_DIRTY`、`NS_BUILD_CHANNEL` 注入 `--dart-define`。

```powershell
pwsh -File tooling/scripts/build.ps1 -Target windows -Release
pwsh -File tooling/scripts/build.ps1 -Target android -Release -EvidenceDir docs/testing/evidence/2026-09-20/t01-01-01
```

| 参数 | 作用 |
| --- | --- |
| `-Target` | `android`、`windows` 或 `ios` |
| `-Release` | 使用 release 模式；缺省为 debug |
| `-EvidenceDir` | 给定目录时把产物 SHA-256 写入 `artifacts-sha256.json` |

行为说明：

- `-Target ios` 在非 macOS 上会明确失败并说明原因，不会静默跳过。
- Android `-Release` 在没有 `android/key.properties` 时由 Flutter 使用调试签名，
  产物**不是分发包**；正式签名属于 T10。
- 每个目标都会打印产物路径与 SHA-256，便于写进证据。
