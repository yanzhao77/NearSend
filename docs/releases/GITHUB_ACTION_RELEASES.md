# GitHub Actions 自动发版

当前发布基线：**[v0.1.1](https://github.com/yanzhao77/NearSend/releases/tag/v0.1.1)**。
该版本由提交 `16981244cf4a756aa5b73035cfd830acc58cabfc` 触发并成功发布。

## 行为

`.github/workflows/release.yml` 在 `master` 的 CI 成功后自动运行，也支持从
GitHub Actions 页面手动 `workflow_dispatch`。发布工作流使用四类原生 runner：

- Ubuntu：Android APK、Linux `amd64` `.deb` 和便携式 `.tar.gz`。
- Windows：Windows `x64` ZIP。
- macOS：macOS `.app` ZIP。

发布 job 会等待四个平台全部构建成功后才创建 GitHub Release。Release tag 使用
`vMAJOR.MINOR.PATCH`，以仓库已有最高版本 tag 为基线递增 patch；没有历史 release
时以 `pubspec.yaml` 的版本为基线并递增 patch。Android、Windows、Linux、macOS
构建都把相同的 Release 版本写入 Flutter build name，Android build number 使用
GitHub Actions run number。

每个 Release 附带 `SHA256SUMS.txt`。发布说明由 GitHub 的自动生成 release notes
接口生成，再追加构建 commit、Flutter 版本、Linux 架构和 Android 当前签名限制。

## 已验证的首次发布

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

后续向 `master` 的提交会先触发 CI；只有 CI 成功，Release 工作流才会以最高版本 tag
为基线递增 patch 并发布下一版。文档提交本身也会走这条路径，因此不能把 GitHub 上的
Release 生成当作本地构建验证的替代品：本项目的构建验证入口是 GitHub Actions。

## 需要人工配置的发布阻断项

当前 Android 工程仍使用 `android/app/build.gradle.kts` 中的 debug signing
configuration。该工作流可以生成可安装的内部测试 APK，但不能把它标记为商店或
正式分发签名包。正式发布前应在 GitHub Environment 中配置签名材料，并修改发布
job 使用受保护 secret；私钥不能提交到仓库或写入普通日志。

macOS 当前输出未签名 ZIP，Linux 输出面向 `amd64`。代码签名、notarization、
多架构构建、Windows MSIX 和 Android Play/AAB 发布不属于本次自动化范围。

此外，当前 Release 仍是预览构建。代码级双节点测试已经覆盖控制面、数据面和界面，
但 Android ↔ Windows 的真实设备双向传输、大文件恢复、Android SAF 和 Windows 取件器
仍需目标设备证据，不能因构建成功而标记产品验收完成。
