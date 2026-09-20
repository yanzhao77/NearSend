# T01-02 CI 与检查 — 运行汇总

- 运行 ID：`t01-02-01`
- 任务：[T01-02 CI 与检查](../../../../tasks/T01-02.md)
- 日期：2026-09-20
- 分支：`feat/t01-02-ci-checks`
- 基线：`master` @ `af5eb486f3f257be82c7074f94a4f58f7dc10b18`
- 本机：Windows 10 22H2 (10.0.19045.6466)，Flutter 3.47.5 / Dart 3.13.4，Python 3.10.9

## 1. 本任务建立的门禁

`.github/workflows/ci.yml` 有四个作业，全部**不使用 `continue-on-error`**，工作流权限为只读：

| 作业 | runner | 内容 |
| --- | --- | --- |
| `repository-checks` | ubuntu-latest | 依赖锁文件已跟踪且非空、协议固定向量、Markdown 相对链接、敏感信息 |
| `flutter-checks` | ubuntu-latest | `flutter pub get` → `dart format` 校验 → `flutter analyze` → `flutter test` |
| `build-android` | ubuntu-latest | JDK 21 + debug/release APK，产物摘要作为工件上传 |
| `build-windows` | windows-latest | Windows release 构建，产物摘要作为工件上传 |

**工具链固定方式**：Flutter 由 `tooling/ci/install_flutter.sh` 安装，版本固定在
`3.47.5`，并在解压前校验归档 SHA-256：

| 平台 | 归档 | SHA-256 |
| --- | --- | --- |
| Linux | `flutter_linux_3.47.5-stable.tar.xz` | `2132e990f236f8d22e7c6314b29a191a95b10d7cbcfec9b4e2e303d996652cbb` |
| Windows | `flutter_windows_3.47.5-stable.zip` | `0ccd71931f49c2fbe394b1eeb6d79af3d624058a043ea0d03d34160581624fb8` |

Windows 摘要在 T01-01 中已由**本地实际下载并独立计算**验证过，与 Flutter 发布元数据一致；
这同时说明元数据可信，Linux 摘要取自同一来源。

## 2. 为什么不用第三方 Action 安装 Flutter

`docs/architecture/APP_AND_SERVICE_DESIGN.md` §12 要求新增依赖前记录用途、替代方案、维护状态、
许可证与安全影响。安装 Flutter 只需要固定版本 + 校验摘要 + 解压，用一个十几行的脚本就能完成，
且版本与摘要留在可评审的源码里；为此把一个第三方 Action 放进供应链并不划算。

### 使用的 Action（全部为 GitHub 官方一方，MIT，活跃维护）

| Action | 固定引用 | 用途 |
| --- | --- | --- |
| `actions/checkout` | `11d5960a326750d5838078e36cf38b85af677262` (# v4.2.2) | 检出仓库 |
| `actions/setup-python` | `a26af69be951a213d495a4c3e4e4022e16d87065` (# v5.3.0) | 提供 Python 3.12 |
| `actions/setup-java` | `cf277c60eb25467037889841efdb72551f06f6c3` (# v4.7.0) | 提供 JDK 21 (temurin) |
| `actions/cache` | `0057852bfaa89a56745cba8c7296529d2fc39830` (# v4.2.0) | 缓存 Flutter SDK |
| `actions/upload-artifact` | `ea165f8d65b6e75b540449e92b4886f43607fa02` (# v4.6.0) | 上传产物摘要 |

**全部固定到 40 位提交 SHA，而不是可移动的标签**——标签被移动会静默改变以本仓库权限运行的代码。
`tooling/checks/check_ci_workflow.py` 会在 CI 中强制这一点。

## 3. 仓库级检查（本地与 CI 同一份实现）

`tooling/checks/` 下三个脚本只用 Python 标准库，因此 Windows、Linux、macOS 与 CI 行为一致，
`check.ps1` 与工作流调用的是同一份规则，不存在两套会分叉的实现：

| 脚本 | 作用 |
| --- | --- |
| `check_links.py` | 校验已跟踪 Markdown 的相对链接；只检查跟踪文件，**不请求外部链接**（CI 不应依赖第三方可访问） |
| `check_secrets.py` | 命中凭证形态即失败；跳过二进制；**输出脱敏**（只打印前 4 字符与长度，避免 CI 日志变成新的泄露） |
| `check_ci_workflow.py` | 强制工作流自身声明的不变量：`uses:` 必须 SHA 固定、禁止 `continue-on-error`、权限只读、Flutter 版本两处一致 |

## 4. 本地验证结果

`tooling/scripts/check.ps1` 完整输出见 `check-script.log`：

```text
flutter pub get                       → 通过
dart format --set-exit-if-changed .   → 通过（无改动）
flutter analyze                       → No issues found!
flutter test                          → 36 / 36 通过
Markdown relative links               → checked 26 files, 141 links, 全部可解析
Sensitive information                 → 153 个跟踪文件未发现凭证材料
CI workflow invariants                → 全部成立
```

### 反例验证（证明闸门不是空转）

完整记录见 `negative-tests.log`。每一项检查都**真的失败过一次**，并在移除缺陷后恢复通过：

| # | 注入的缺陷 | 期望 | 实际 |
| --- | --- | --- | --- |
| 1 | 已跟踪 Markdown 中的坏相对链接 | 退出 1 | 退出 1，并精确指出文件与目标 |
| 2 | 已跟踪文件中的假 GitHub 令牌 | 退出 1 且输出脱敏 | 退出 1，输出为 `ghp_...<40 chars>` |
| 3 | 把 Action 从 SHA 改成 `@v4` | 退出 1 | 退出 1，列出 4 处未固定 |
| 4 | 给某个步骤加 `continue-on-error: true` | 退出 1 | 退出 1 |
| 5 | 工作流 Flutter 版本改成 `3.99.9` | 退出 1 | 退出 1，指出与安装脚本不一致 |
| 6 | 还原工作流 | 退出 0 | 退出 0 |

**没有提交任何反例夹具**；执行后工作区只剩本任务预期的改动。

## 5. 行尾策略

新增 `.gitattributes`：`* text=auto eol=lf`、`.bat`/`.cmd` 保持 CRLF、常见二进制扩展名显式声明。
动机是真实存在的：Dart 格式化器输出 LF，在 `core.autocrlf=true` 的 Windows 检出上，
同一个提交可能在 Linux CI 通过而在 Windows 失败。

执行 `git add --renormalize .` 后**只有本任务自己修改的文件被暂存**，没有任何既有文件内容变化，
说明仓库本就以 LF 存储，本文件不引入历史改写。

## 6. 已知限制与未执行项

- 本机没有 `pwsh`（只有 Windows PowerShell 5.1），因此 `check.ps1` 在本机以
  `powershell -NoProfile -ExecutionPolicy Bypass` 运行；CI 的 ubuntu runner 使用 `pwsh` 运行
  `build.ps1`。两条路径的脚本同一份，但**`build.ps1` 在 Linux 上的首次真实运行由 CI 完成**。
- 本任务不涉及签名、发布与密钥托管：CI 只读，签名材料与商店凭证属于 T10。
- 未在本机验证 macOS runner（iOS 构建仍阻塞于 Apple 硬件，见 B06/T09）。
- 首次 CI 的 Android 作业可能需要额外下载 Flutter 默认 `ndkVersion`（28.2.13676358），
  耗时较长；若超时会改为显式安装并记录。
