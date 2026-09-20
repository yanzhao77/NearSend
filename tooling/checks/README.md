# NearSend 仓库检查脚本

本目录存放**与 Flutter 工具链无关**的仓库级检查。它们只用 Python 标准库，因此
Windows、Linux、macOS 与 CI runner 上行为一致，不需要安装任何第三方包。

`tooling/scripts/check.ps1` 与 `.github/workflows/ci.yml` 都直接调用这些脚本，
所以本地与 CI 执行的是**同一份规则**，而不是两套会逐渐分叉的实现。

## 为什么用 Python 标准库

`docs/architecture/APP_AND_SERVICE_DESIGN.md` §12 要求新增依赖前记录用途、替代方案、维护状态、
许可证与安全影响。这三项检查都是纯文本处理，标准库足够；为了跑一次链接检查而引入 PyYAML
之类的依赖并不划算。`tooling/s0` 已经是同一套约定。

## `check_links.py`

校验**已被 Git 跟踪**的 Markdown 文件中的相对链接能否解析。

- 只检查跟踪文件，因此 `build/`、`.dart_tool/`、Flutter SDK 缓存不会产生噪声。
- **不请求外部链接**：CI 不应依赖第三方站点可访问，一次网络抖动不该让构建失败。
- 处理 `#锚点`、`%xx` 百分号编码（本仓库文档名含中文）以及 `[文本](目标 "标题")` 形式。
- **跳过代码块、行内代码与 HTML 注释**：文档为了举例而写出链接语法时，例子不是链接。
  （这一条是被 CI 抓出来的：本文件的示例文本最初被当成真实链接，报了一次假的坏链接。）
- 若工作区存在**未跟踪**的 Markdown，会明确列出并打印 `WARNING`，且最终结论行会注明
  「tracked files only」。加 `--strict` 时**直接失败**，提示先 `git add`。
  `check.ps1` 使用 `--strict`：一个不覆盖工作区的「通过」是误导性的，
  而修好它只需要把文件暂存。（本项目两次把坏链接送进 CI，都是因为在文件仍未被跟踪时
  跑了一次本地检查。）

```bash
python3 tooling/checks/check_links.py
python3 tooling/checks/check_links.py --verbose
python3 tooling/checks/check_links.py --strict
```

退出码：`0` 全部可解析，`1` 存在坏链接或（在 `--strict` 下）存在未跟踪的 Markdown，`2` 用法错误。

## `check_secrets.py`

扫描已被 Git 跟踪的文件，命中凭证形态即失败。

- 只检查跟踪文件；跳过二进制文件（编译产物里出现 `-----BEGIN ... KEY-----` 是正常现象）。
- **输出经过脱敏**：只显示前 4 个字符与长度。把命中的密钥原样打到 CI 日志里，
  等于制造一次新的泄露，而这正是本检查要防的事。
- 短值不会被通用赋值规则命中，否则会误报 UI dump 里的 `password="false"`。
- 某一行若包含 `nearsend-secret-scan: allow` 标记则跳过，便于文档**故意**展示令牌格式；
  该标记在评审中可见，也容易 grep。

```bash
python3 tooling/checks/check_secrets.py
python3 tooling/checks/check_secrets.py --verbose
```

退出码：`0` 未发现，`1` 发现命中，`2` 用法错误。

## `check_ci_workflow.py`

把 `.github/workflows/ci.yml` 自己在注释里声明的不变量变成**可执行的检查**。
注释里的承诺不是保证，因此本脚本强制：

- 每个 `uses:` 都固定到 40 位提交 SHA——标签被移动会静默改变以本仓库权限运行的代码；
- 不存在 `continue-on-error`——不能失败的闸门不是闸门；
- `permissions` 保持只读；
- 工作流的 `FLUTTER_VERSION` 与 `tooling/ci/install_flutter.sh` 中安装的版本一致，两处不得漂移。

```bash
python3 tooling/checks/check_ci_workflow.py
```

退出码：`0` 不变量成立，`1` 存在违规，`2` 用法错误。

## 在本地一次跑完全部检查

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tooling/scripts/check.ps1
```

该脚本按固定顺序执行：`flutter pub get` → `dart format` 校验 → `flutter analyze` →
`flutter test` → 上面三项仓库检查；任一步失败立即以非零码退出。
如果机器上没有 Python，脚本会**明确打印 SKIPPED**，而不是假装通过。
