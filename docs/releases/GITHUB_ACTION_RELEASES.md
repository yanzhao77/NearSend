# GitHub Actions 自动发版

截至 2026-09-29 的预览发布基线：**[v0.1.14](https://github.com/yanzhao77/NearSend/releases/tag/v0.1.14)**。
该版本对应 `master` 提交 `dd90cb7d425a2d5af396d920a27b6ea60c1177d7`；CI 与发布工作流成功，但它仍是 prerelease，不是正式签名分发。PR #78 的 1418 项 Flutter 测试及 Android debug APK 构建通过；没有目标设备回归。

## 行为

`.github/workflows/release.yml` 在 `master` 的 CI 成功后自动运行，也支持从
GitHub Actions 页面手动 `workflow_dispatch`。手动触发必须输入完整目标 SHA；工作流会
确认它位于 `master` 历史中，并且该精确 SHA 已有成功的 `master` push CI。发布工作流使用四类原生 runner：

- Ubuntu：Android APK、Linux `amd64` `.deb` 和便携式 `.tar.gz`。
- Windows：Windows `x64` ZIP。
- macOS：macOS `.app` ZIP。

发布 job 会等待四个平台全部构建成功后才创建标为 **prerelease** 的 GitHub Release。当前工作流没有 stable 发布路径，因此该自动化不能完成正式发版。Release tag 使用
`vMAJOR.MINOR.PATCH`，以仓库已有最高版本 tag 为基线递增 patch；没有历史 release
时以 `pubspec.yaml` 的版本为基线并递增 patch。Android、Windows、Linux、macOS
构建都把相同的 Release 版本写入 Flutter build name，Android build number 使用
GitHub Actions run number。

每个 Release 附带 `SHA256SUMS.txt`。发布说明由 GitHub 的自动生成 release notes
接口生成，再追加构建 commit、Flutter 版本、Linux 架构和 Android 当前签名限制。

## 最新发布流水线

- CI：[run 36458681128](https://github.com/yanzhao77/NearSend/actions/runs/36458681128)
- Release：[run 36459384791](https://github.com/yanzhao77/NearSend/actions/runs/36459384791)
- Release 页面：[NearSend v0.1.14](https://github.com/yanzhao77/NearSend/releases/tag/v0.1.14)
- 目标提交：`dd90cb7d425a2d5af396d920a27b6ea60c1177d7`
- 资产：Android APK、Windows x64 ZIP、macOS ZIP、Linux amd64 DEB/便携包、`SHA256SUMS.txt`

## 已验证的发布

`v0.1.1` 已在 GitHub 上完成完整流水线：

- CI：[run 35692614466](https://github.com/yanzhao77/NearSend/actions/runs/35692614466)
- Release：[run 35692935979](https://github.com/yanzhao77/NearSend/actions/runs/35692935979)
- Release 页面：[NearSend v0.1.1](https://github.com/yanzhao77/NearSend/releases/tag/v0.1.1)

实际上传的资产：

- `NearSend-0.1.1-android.apk`
- `NearSend-0.1.1-windows-x64.zip`
- `NearSend-0.1.1-macos.zip`
- `NearSend-0.1.1-linux-amd64.deb`
- `NearSend-0.1.1-linux-x64.tar.gz`
- `SHA256SUMS.txt`

`v0.1.3` 于 2026-09-23 发布，记录了 macOS 构建故障修复后的完整流水线：

- [PR #63](https://github.com/yanzhao77/NearSend/pull/63) 修复 CI/Release 门禁兼容性；[PR #64](https://github.com/yanzhao77/NearSend/pull/64) 加入 Flutter 3.47.5 macOS AOT windowing 临时补丁，但首次 Release [run 35846736222](https://github.com/yanzhao77/NearSend/actions/runs/35846736222) 因目标声明实际为 `final class` 而失败。
- [PR #65](https://github.com/yanzhao77/NearSend/pull/65) 将补丁匹配改为 `final class`，合并提交为 `ae4a2db3c86963e07376d9521d606de0090859eb`；补丁仍限定在 CI 的 Flutter SDK 缓存中，并校验固定版本与五个目标声明。
- 合并后 CI：[run 35848077863](https://github.com/yanzhao77/NearSend/actions/runs/35848077863)，仓库检查、格式/分析/测试、Android 与 Windows 构建均成功。
- Release：[run 35848571953](https://github.com/yanzhao77/NearSend/actions/runs/35848571953)，Android、Windows、Linux、macOS 构建及发布 job 均成功；[macOS 构建日志](https://github.com/yanzhao77/NearSend/actions/runs/35848571953/job/107140604091) 确认补丁应用并构建 `nearsend.app`。
- Release 页面：[NearSend v0.1.3](https://github.com/yanzhao77/NearSend/releases/tag/v0.1.3)。实际资产为 `NearSend-0.1.3-android.apk`、`NearSend-0.1.3-windows-x64.zip`、`NearSend-0.1.3-macos.zip`、`NearSend-0.1.3-linux-amd64.deb`、`NearSend-0.1.3-linux-x64.tar.gz` 和 `SHA256SUMS.txt`。

macOS 临时补丁仅经此次 Flutter 3.47.5 构建验证；升级 Flutter 后应重新核对上游修复与补丁适用性。构建成功不等于安装、签名、升级或目标设备传输验收完成。

后续向 `master` 的提交会先触发 CI；只有 CI 成功，Release 工作流才会以最高版本 tag
为基线递增 patch 并发布下一预览版。手动入口也不能绕过这项门禁。文档提交本身同样会走这条路径，因此不能把 GitHub 上的
Release 生成当作本地构建验证的替代品：本项目的构建验证入口是 GitHub Actions。

## 需要人工配置的发布阻断项

当前 Android 工程仍使用 `android/app/build.gradle.kts` 中的 debug signing
configuration。该工作流可以生成可安装的内部测试 APK，但不能把它标记为商店或
正式分发签名包。正式发布前应在 GitHub Environment 中配置签名材料，并修改发布
job 使用受保护 secret；私钥不能提交到仓库或写入普通日志。

macOS 当前输出未签名 ZIP，Linux 输出面向 `amd64`。代码签名、notarization、
多架构构建、Windows MSIX 和 Android Play/AAB 发布不属于本次自动化范围。

此外，当前 Release 仍是预览构建。正式发布还需先完成 Android 正式签名、macOS 签名与公证（或明确平台支持范围）、stable 工作流/发布说明，以及最新版本的目标设备验收；不能仅把当前 prerelease 去掉标记来替代这些门槛。代码级双节点测试已经覆盖控制面、数据面和界面，
但 Android ↔ Windows 的真实设备双向传输、大文件恢复、Android SAF 和 Windows 取件器
仍需目标设备证据，不能因构建成功而标记产品验收完成。
