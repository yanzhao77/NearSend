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
| V12-03 设置与接收确认定向测试 | 通过 | 设置页与接收页 18 项通过；两个真实 TLS UI 文件传输用例纳入全量回归 |
| V12-03 全量测试 | 通过 | `fvm flutter test --reporter compact`，1285 项全部通过；`flutter analyze` 无问题 |
| V12-04 身份与迁移定向测试 | 通过 | 长期身份载荷、schema v8→v9、公开元数据、peer 历史、节点重启和 MethodChannel 测试通过 |
| V12-04 全量测试 | 通过 | `fvm flutter test --reporter compact`，1301 项全部通过；覆盖旧数据库首次建立身份与已绑定身份丢失后的失败关闭 |
| V12-04 Android Kotlin 编译 | 通过 | `:app:compileDebugKotlin` 成功，含 Keystore AES-GCM 身份存储 |
| V12-04 Windows DPAPI 编译 | 受阻 | 当前主机不是 Windows；必须由 Windows CI/主机验证 C++ 编译和当前用户作用域持久化 |
| V12-05 mDNS 定向测试 | 通过 | TXT 最小化、严格解析、地址过滤、自发现抑制、并发启动、资源撤销及节点生命周期共 12 项通过 |
| V12-05 全量测试 | 通过 | `fvm flutter test --reporter compact`，1308 项全部通过 |
| V12-05 Android Kotlin 编译 | 通过 | 主应用及 `bonsoir_android 7.1.3` 编译成功；插件有旧 NSD API 弃用警告 |
| V12-05 iOS Simulator 构建 | 通过 | `fvm flutter build ios --simulator` 成功，生成 `Runner.app`；验证 Bonjour 声明和 Darwin 插件链接 |
| V12-05 iOS 设备构建 | 受阻 | `flutter build ios --no-codesign` 进入 Xcode 后仍要求 Development Team/Provisioning Profile，未产出设备包 |
| Android Kotlin 编译 | 通过 | `./gradlew :app:compileDebugKotlin -x :app:compileFlutterBuildDebug`，BUILD SUCCESSFUL |
| Android APK 构建 | 受阻 | `flutter build apk --debug` 在下载 `sqlite3 3.6.0` 的 Android 原生库时 TLS 握手中断；未产出 APK |
| macOS 构建 | 未执行 | 集成阶段执行；不替代 Android/Windows 目标验收 |
| Windows 构建 | 受阻 | 当前主机不是 Windows；由 GitHub Actions 或 Windows 主机执行 |
| iOS 构建 | 部分通过 | Simulator 构建通过；设备无签名构建受 Development Team/Provisioning 阻断，不能替代真机 |

## 实机矩阵

| 用例 | 状态 | 证据或阻塞 |
|---|---|---|
| A01 Android ↔ Windows，同一 Wi-Fi | 未执行 | 需要本轮双机证据 |
| A02 Android ↔ Windows，不同 Wi-Fi，BLE 配对与热点 | 未执行 | 需要目标硬件与 Windows 主机 |
| A03 无路由器、无互联网 | 未执行 | 需要 Android 热点与 Windows 加入实测 |
| A04 AP 隔离或 mDNS 阻断 | 未执行 | 失败状态和手动连接保留已有自动化；仍需要可控网络环境验证真实发现丢失 |
| A05 蓝牙关闭或拒权后的二维码路径 | 未执行 | 需要目标设备 |
| A06 Windows 无摄像头导入二维码图片 | 未执行 | 需要 Windows 主机 |
| A07 Windows 无 BLE 外设能力 | 未执行 | 需要对应蓝牙适配器 |
| A08 蜂窝网络与无互联网热点并存 | 未执行 | 需要 Android 真机与路由检查 |
| A09 重启与热点 IP 改变 | 未执行 | 稳定身份尚未实现 |
| A10 同名设备或身份指纹变化 | 未执行 | 自动化负例与双机实测均待完成 |
| A11 默认目录重启持久化 | 未执行 | 设置页选择、权限验证、持久化和默认填充已有自动化；仍需 Android/Windows 真机重启并实际写入 |
| A12 单/多文件、同名、中文和长名称 | 未执行 | 单弹框多文件改名、中文改名、同名自动重命名和非法名阻断已有自动化；仍需 Android/Windows 实机组合验证 |
| A13 目录授权撤销或目录删除 | 未执行 | 接收前撤权阻断和设置修复入口、输出失败持久化与保留暂存已有自动化；仍需真机撤权/删除目录验证 |
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

## V12-03 自动化证据

2026-09-24 在 macOS/FVM Flutter 3.47.5 环境执行：

```text
fvm flutter analyze
结果：No issues found

fvm flutter test test/features/settings/settings_page_test.dart \
  test/features/transfer/receive_page_test.dart
结果：18 tests passed

fvm flutter test --reporter compact
结果：1285 tests passed
```

## V12-04 第一阶段自动化证据

2026-09-24 在 macOS/FVM Flutter 3.47.5 环境执行：

```text
fvm flutter analyze
结果：No issues found

fvm flutter test test/core/security/installation_identity_test.dart \
  test/core/storage/installation_identity_repository_test.dart \
  test/core/storage/peer_repository_test.dart \
  test/core/storage/storage_migration_test.dart \
  test/platform/platform_identity_store_test.dart \
  test/app/node_runtime_test.dart test/app/node_session_test.dart
结果：通过

fvm flutter test --reporter compact
结果：1301 tests passed

./gradlew :app:compileDebugKotlin -x :app:compileFlutterBuildDebug
结果：BUILD SUCCESSFUL
```

## V12-05 mDNS 自动化与构建证据

2026-09-24 在 macOS/FVM Flutter 3.47.5 环境执行：

```text
fvm flutter test test/platform/mdns_discovery_gateway_test.dart \
  test/app/node_session_test.dart --reporter compact
结果：12 tests passed

fvm flutter test --reporter compact
结果：1308 tests passed

./gradlew :app:compileDebugKotlin -x :app:compileFlutterBuildDebug
结果：BUILD SUCCESSFUL；bonsoir_android 编译通过，报告旧 NSD API 弃用警告

fvm flutter build ios --simulator
结果：成功，生成 build/ios/iphonesimulator/Runner.app

fvm flutter build ios --no-codesign
结果：受阻，Xcode 要求 Development Team 和 Provisioning Profile

fvm flutter build apk --debug
结果：受阻，sqlite3 3.6.0 Android 原生库下载发生 TLS handshake terminated
```

## 证据规则

实机记录至少包含设备型号、系统版本、网络条件、NearSend 提交号、操作步骤、结果和必要的
脱敏日志。不得记录配对秘密、热点密码、私钥、恢复凭证或用户文件内容。
