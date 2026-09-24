# NearSend 1.2 验收记录

更新日期：2026-09-24

状态说明：`通过` 必须有命令或实机证据；`未执行` 表示没有证据；`受阻` 必须写明缺失条件。
自动化测试不能替代实机网络、权限和生命周期验证。

## 自动化与构建

| 检查 | 状态 | 结果或阻塞 |
|---|---|---|
| FVM Flutter 版本 | 通过 | Flutter 3.47.5 / Dart 3.13.4 |
| `flutter analyze` 基线 | 通过 | 2026-09-24，`No issues found` |
| `flutter test` 基线 | 通过 | macOS 改用系统 SQLite 后，1256 项全部通过 |
| Markdown 相对链接 | 通过 | V12-00：95 个文件、534 个链接通过 |
| 敏感信息扫描 | 通过 | V12-00 基线提交前通过 |
| V12-01 定向测试 | 通过 | 位置模型、设置迁移、Android/Windows MethodChannel、空间读模型和 SAF 导出共 28 项通过 |
| V12-01 全量测试 | 通过 | `flutter test`，1267 项全部通过 |
| V12-02 定向测试 | 通过 | 输出计划、v7→v8 迁移、导出、鉴权及两个真实 TLS 接收方向共 102 项通过 |
| V12-02 全量测试 | 通过 | `fvm flutter test --reporter compact`，1275 项全部通过；`flutter analyze` 无问题 |
| Android Kotlin 编译 | 通过 | `./gradlew :app:compileDebugKotlin -x :app:compileFlutterBuildDebug`，BUILD SUCCESSFUL |
| Android APK 构建 | 受阻 | `flutter build apk --debug` 在下载 `sqlite3 3.6.0` 的 Android 原生库时 TLS 握手中断；未产出 APK |
| macOS 构建 | 未执行 | 集成阶段执行；不替代 Android/Windows 目标验收 |
| Windows 构建 | 受阻 | 当前主机不是 Windows；由 GitHub Actions 或 Windows 主机执行 |
| iOS 构建 | 未执行 | 非 1.2 首要完整验收组合，仍需保持可编译性 |

## 实机矩阵

| 用例 | 状态 | 证据或阻塞 |
|---|---|---|
| A01 Android ↔ Windows，同一 Wi-Fi | 未执行 | 需要本轮双机证据 |
| A02 Android ↔ Windows，不同 Wi-Fi，BLE 配对与热点 | 未执行 | 需要目标硬件与 Windows 主机 |
| A03 无路由器、无互联网 | 未执行 | 需要 Android 热点与 Windows 加入实测 |
| A04 AP 隔离或 mDNS 阻断 | 未执行 | 需要可控网络环境 |
| A05 蓝牙关闭或拒权后的二维码路径 | 未执行 | 需要目标设备 |
| A06 Windows 无摄像头导入二维码图片 | 未执行 | 需要 Windows 主机 |
| A07 Windows 无 BLE 外设能力 | 未执行 | 需要对应蓝牙适配器 |
| A08 蜂窝网络与无互联网热点并存 | 未执行 | 需要 Android 真机与路由检查 |
| A09 重启与热点 IP 改变 | 未执行 | 稳定身份尚未实现 |
| A10 同名设备或身份指纹变化 | 未执行 | 自动化负例与双机实测均待完成 |
| A11 默认目录重启持久化 | 未执行 | Android 代码已实现，仍需真机选择目录、重启并实际写入；Windows 尚未实现 |
| A12 单/多文件、同名、中文和长名称 | 未执行 | 中文改名、同名自动重命名和多文件模型已有自动化；仍需 Android/Windows 实机组合验证 |
| A13 目录授权撤销或目录删除 | 未执行 | Android 已有授权复查、输出失败持久化和保留暂存路径；仍需真机撤权/删除目录验证 |
| A14 拒绝、超时和撤销邀请 | 未执行 | 拒绝不创建内容/输出计划已有自动化；超时、撤销与真机资源清理仍待验证 |
| A15 关闭就绪、后台和断网 | 未执行 | V12-10/V12-11 尚未实现 |
| A16 大文件和大量小文件 | 未执行 | 集成后执行，需含超过 4 GiB 样本 |
| A17 Android ↔ Android，不同网络 | 未执行 | 需要两台 Android 设备 |
| A18 历史设备离线后熄灯 | 未执行 | V12-10 尚未实现 |
| A19 QR 过期、复用和篡改 | 未执行 | V12-09 尚未实现 |
| A20 热点会话结束或取消后的清理 | 未执行 | V12-08/V12-11 尚未实现 |

## V12-01 自动化证据

2026-09-24 在 macOS/FVM Flutter 3.47.5 环境执行：

```text
fvm flutter analyze
结果：No issues found

fvm flutter test test/platform/storage_location_test.dart \
  test/platform/platform_storage_gateway_test.dart \
  test/platform/android_file_gateway_test.dart \
  test/platform/android_export_sink_test.dart \
  test/app/application/app_settings_repository_test.dart \
  test/app/application/space_overview_controller_test.dart
结果：28 tests passed

./gradlew :app:compileDebugKotlin -x :app:compileFlutterBuildDebug
结果：BUILD SUCCESSFUL

fvm flutter build apk --debug
结果：受阻，下载 libsqlite3.arm.android.so 时 TLS handshake terminated
```

## V12-02 自动化证据

2026-09-24 在 macOS/FVM Flutter 3.47.5 环境执行：

```text
fvm dart format --output=none --set-exit-if-changed .
结果：198 files，0 changed

fvm flutter analyze
结果：No issues found

fvm flutter test --reporter compact
结果：1275 tests passed

python3 tooling/checks/check_links.py --strict
结果：95 个 Markdown 文件、536 个链接通过

python3 tooling/checks/check_secrets.py
结果：458 个受跟踪文件未发现凭证材料

python3 tooling/checks/check_ci_workflow.py
结果：CI workflow invariants hold
```

## 证据规则

实机记录至少包含设备型号、系统版本、网络条件、NearSend 提交号、操作步骤、结果和必要的
脱敏日志。不得记录配对秘密、热点密码、私钥、恢复凭证或用户文件内容。
