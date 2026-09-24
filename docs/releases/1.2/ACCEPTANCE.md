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
| V12-04 Windows DPAPI 编译 | 通过 | PR #68 CI run `35961651508` 的 Windows release 构建成功；当前用户作用域持久化仍需 Windows 主机实测 |
| V12-05 mDNS 定向测试 | 通过 | TXT 最小化、严格解析、地址过滤、自发现抑制、并发启动、资源撤销及节点生命周期共 12 项通过 |
| V12-05 全量测试 | 通过 | `fvm flutter test --reporter compact`，1308 项全部通过 |
| V12-05 Android Kotlin 编译 | 通过 | 主应用及 `bonsoir_android 7.1.3` 编译成功；插件有旧 NSD API 弃用警告 |
| V12-05 iOS Simulator 构建 | 通过 | `fvm flutter build ios --simulator` 成功，生成 `Runner.app`；验证 Bonjour 声明和 Darwin 插件链接 |
| V12-05 iOS 设备构建 | 受阻 | `flutter build ios --no-codesign` 进入 Xcode 后仍要求 Development Team/Provisioning Profile，未产出设备包 |
| V12-06 BLE 定向测试 | 通过 | 广告边界、20 字节帧、16 KiB 消息、截断、坏版本、重复、乱序、重放、超时、对端上限、并发发送串行化、双向网关与生命周期共 14 项通过 |
| V12-06 全量测试 | 通过 | `fvm flutter test --reporter compact`，1322 项全部通过；`flutter analyze` 无问题 |
| V12-06 Android Kotlin/插件编译 | 通过 | 首次 Maven TLS 握手中断；重试后主应用和 `bluetooth_low_energy_android 6.2.1` 均编译成功，插件报告旧 GATT API/Kotlin Gradle Plugin 弃用警告 |
| V12-06 iOS Simulator 构建 | 通过 | `fvm flutter build ios --simulator` 成功，生成 `Runner.app`；只证明依赖链接和用途说明有效，默认 BLE 适配仍未开放 iOS 路径 |
| V12-06 Windows 插件编译 | 通过 | 首轮 CI 在 VS 2026 因上游 `/await` 的 STL1011 失败；提交 `d9e02e0` 限定兼容宏后，run `35961651508` 构建成功 |
| V12-06 Android/Windows BLE 双机 | 未执行 | 缺少本轮 Android/Windows BLE 目标设备；不得用模拟事件代替广告、GATT、MTU、权限和生命周期实测 |
| V12-07 已知设备认证定向测试 | 通过 | 42 项通过；覆盖签名、TLS pin/ready 绑定、重放、过期、撤销、身份替换、角色反射、容量和严格 wire 解析 |
| V12-07 首次短码 PAKE | 受阻 | `spake2plus 1.0.2` 缺目标平台，`dsrp 0.5.5` 未达到审计/测试门槛；未接入不合格实现 |
| V12-07 Android/Windows 双向认证 | 未执行 | 缺少本轮双机环境；自动化不能替代 BLE 控制链路上的真实身份挑战 |
| V12-08 网络网关定向测试 | 通过 | 7 项通过；覆盖凭据文本脱敏、MethodChannel 参数/错误分类、认证探测顺序、候选上限/超时及公网/回环拒绝 |
| V12-08 Android Kotlin 编译 | 通过 | `LocalOnlyHotspot`、`WifiNetworkSpecifier`、权限和 lease 生命周期代码编译成功 |
| V12-08 Android 热点传输 | 未执行 | 缺 Android/Windows 双机；指定 Android `Network` 尚未与 Flutter HTTPS socket 完成绑定验证 |
| V12-08 Windows 自动入网 | 受阻 | 当前主机非 Windows；能力诚实报告为不支持，仅提供系统 Wi-Fi 设置回退 |
| V12-09 Bootstrap 载荷测试 | 通过 | 7 项通过；覆盖严格分发、旧码兼容、身份绑定、重复/额外字段、热点模式、安全类型、有效期和超限输入 |
| V12-09 二维码图像与平台导入实机 | 未执行 | 依赖和代码级入口已实现，但文本/组件测试不能替代摄像头和 Windows 图片导入实测 |
| V12-09 QR 图像定向测试 | 通过 | 真实 QR PNG 生成/ZXing 往返、空/超限/非图片拒绝及连接页回归共 26 项通过 |
| V12-09 iOS Simulator 构建 | 通过 | `mobile_scanner 7.1.3` Darwin 插件链接并生成 Runner.app；不替代真机摄像头 |
| V12-09 Android 扫码构建 | 通过 | 本机后续 debug APK 与 CI run `35961072170` 的 debug/release APK 构建成功；不替代真机摄像头验证 |
| V12-09 Windows 图片导入编译 | 通过 | PR #68 CI run `35961651508` 的 Windows release 构建成功；IFileOpenDialog 交互仍需 Windows 主机实测 |
| V12-09 全量测试 | 通过 | `fvm flutter test --reporter compact`，1353 项全部通过 |
| V12-09 统一入口定向测试 | 通过 | 连接页 25 项通过；bootstrap 扫描值进入网络感知回调，旧 `lft-pair` 保持原路径 |
| V12-10 雷达定向测试 | 通过 | 22 项通过；覆盖默认关闭、显式 mDNS 启停、BLE/mDNS 候选无灯、新鲜授权证明绿灯、过期/撤销熄灯、窄屏长名称和响应式壳 |
| V12-10 静态分析 | 通过 | `fvm flutter analyze`，`No issues found` |
| V12-10 应用流程回归 | 通过 | `test/app/app_test.dart` 6 项通过；发送、接收、节点失败和真实 TLS 文件流程保持可用 |
| V12-10 全量回归 | 通过 | 修正首页主操作顺序和新增测试滚动后，`fvm flutter test --reporter compact` 1361 项通过；此前失败运行保留为修复过程 |
| V12-10 BLE/mDNS 生产挑战 | 受阻 | 安全挑战实现尚未接入生产控制消息；PAKE 无合格跨平台实现，不能从未认证候选静默建立信任 |
| V12-11 文件动作定向测试 | 通过 | 平台通道、引用边界、结构化错误、接收结果、任务详情、SQLite 最终句柄和双向导出句柄共 29 项通过 |
| V12-11 生命周期测试 | 通过 | 应用进入 `paused` 后雷达返回关闭且 BLE 会话释放；扫码控制器改为显式页面生命周期所有权 |
| V12-11 静态分析 | 通过 | `fvm flutter analyze`，`No issues found` |
| V12-11 全量回归 | 通过 | `fvm flutter test --reporter compact`，1369 项全部通过 |
| V12-11 Android Kotlin/APK 编译 | 通过 | 首次 Maven TLS 下载失败；`fvm flutter build apk --debug` 自动重试后成功，新增 SAF/FileProvider 代码完成编译，产出 `app-debug.apk` |
| V12-11 Windows Shell 编译 | 通过 | PR #68 CI run `35961651508` 的 Windows release 构建成功；`ShellExecuteW` 与 `SHOpenFolderAndSelectItems` 仍需交互实测 |
| Android Kotlin 编译 | 通过 | `./gradlew :app:compileDebugKotlin -x :app:compileFlutterBuildDebug`，BUILD SUCCESSFUL |
| Android APK 构建 | 通过 | `fvm flutter build apk --debug` 首次 Maven TLS 下载失败后自动重试成功，产出 `build/app/outputs/flutter-apk/app-debug.apk` |
| macOS 构建 | 不适用 | 仓库没有 macOS desktop target；SDK 下载重试后 Flutter 明确报告未配置，未伪报构建通过 |
| Windows 构建 | 通过 | PR #68 CI run `35961651508`：Windows release 构建成功；不等同于 BLE/WLAN/Shell 实测 |
| iOS 构建 | 部分通过 | Simulator 构建通过；设备无签名构建受 Development Team/Provisioning 阻断，不能替代真机 |
| V12-12 Markdown 链接 | 通过 | 严格检查 104 个跟踪 Markdown 文件、548 个相对链接，无断链 |
| V12-12 敏感信息扫描 | 通过 | 506 个跟踪文件未发现凭证材料 |
| V12-12 CI 工作流约束 | 通过 | Action 固定 SHA、无 `continue-on-error`、只读权限、Flutter 版本一致 |
| V12-12 S0 Python 探针 | 部分通过 | 协议/存储 21 项通过；Xcode Python 3.9/LibreSSL 2.8.3 不支持 TLS 1.3，TLS 测试类初始化受阻 |

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
| A09 重启与热点 IP 改变 | 未执行 | 稳定身份持久化与节点重启自动化已通过；热点 IP 改变后的双机连续性仍需实测 |
| A10 同名设备或身份指纹变化 | 未执行 | 身份替换、签名篡改和同名不自动信任已有自动化负例；仍需双机实测 |
| A11 默认目录重启持久化 | 未执行 | 设置页选择、权限验证、持久化和默认填充已有自动化；仍需 Android/Windows 真机重启并实际写入 |
| A12 单/多文件、同名、中文和长名称 | 未执行 | 单弹框多文件改名、中文改名、同名自动重命名和非法名阻断已有自动化；仍需 Android/Windows 实机组合验证 |
| A13 目录授权撤销或目录删除 | 未执行 | 接收前撤权阻断和设置修复入口、输出失败持久化与保留暂存已有自动化；仍需真机撤权/删除目录验证 |
| A14 拒绝、超时和撤销邀请 | 未执行 | 拒绝不创建内容/输出计划已有自动化；超时、撤销与真机资源清理仍待验证 |
| A15 关闭就绪、后台和断网 | 自动化部分通过 | 默认关闭、显式关闭、证明过期熄灯和进入后台停止 BLE 雷达已有自动化；真实 BLE/mDNS、网络切换及系统后台限制仍需目标设备 |
| A16 大文件和大量小文件 | 未执行 | 集成后执行，需含超过 4 GiB 样本 |
| A17 Android ↔ Android，不同网络 | 未执行 | 需要两台 Android 设备 |
| A18 历史设备离线后熄灯 | 自动化部分通过 | 证明过期、撤销和关闭就绪后熄灯已有状态机测试；真实掉线与发现来源消失仍需双机实测 |
| A19 QR 过期、复用和篡改 | 自动化部分通过 | 过期、身份替换、重复/额外字段和一次性令牌路径已有负例；摄像头/导图后的真实复用与篡改仍需目标设备 |
| A20 热点会话结束或取消后的清理 | 自动化部分通过 | Dart lease 失败/销毁释放及 Android Activity `close()` 路径已有代码与网关测试；真实热点 reservation、系统确认取消和原网络恢复仍需双机实测 |

## V12-11 系统动作与生命周期证据

2026-09-24 在 macOS/FVM Flutter 3.47.5 环境执行：

```text
fvm dart format --output=none --set-exit-if-changed .
结果：226 files，0 changed

fvm flutter analyze
结果：No issues found

fvm flutter test --reporter compact
结果：1369 tests passed

cd android
./gradlew :app:compileDebugKotlin -x :app:compileFlutterBuildDebug
结果：失败；Maven Central TLS 握手中断，未进入本次 Kotlin 源码编译
```

Windows C++ 已由后续 PR CI 编译；未执行 Android/Windows 系统打开与定位、Android SAF 撤权、真实
后台切换和热点资源回收实测。macOS 自动化只验证 Dart 契约、状态机和真实本地文件导出，不构成
平台 Shell/Intent 交互证据。

后续 V12-12 重试中 `fvm flutter build apk --debug` 自动重试 Maven 下载后成功，因此上表将 Android
编译更新为通过；这不改变系统动作和权限生命周期仍缺真机证据的结论。

## V12-10 首页雷达证据

2026-09-24 在 macOS/FVM Flutter 3.47.5 环境执行：

```text
fvm dart format --output=none --set-exit-if-changed .
结果：223 files，0 changed

fvm flutter test test/app/application/radar_controller_test.dart \
  test/features/home/home_page_test.dart \
  test/app/presentation/app_shell_test.dart \
  test/app/node_session_test.dart --reporter compact
结果：22 tests passed

fvm flutter analyze
结果：No issues found

fvm flutter test test/app/app_test.dart --reporter compact
结果：6 tests passed

fvm flutter test --reporter compact
结果：1361 tests passed
```

没有执行 Android/Windows 双机雷达、BLE 权限/适配器关闭、后台恢复和生产挑战交换。自动化中的
模拟事件只验证状态边界，不构成无线发现、绿灯或可信配对的实机证据。

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

## V12-07 已知设备认证自动化证据

2026-09-24 在 macOS/FVM Flutter 3.47.5 环境执行：

```text
fvm flutter test test/core/security/known_peer_authentication_test.dart \
  test/core/security/installation_identity_test.dart \
  test/core/storage/peer_repository_test.dart \
  test/core/security/pairing_service_test.dart --reporter expanded
结果：42 tests passed

fvm flutter analyze
结果：No issues found

fvm flutter test --reporter compact
结果：1337 tests passed
```

首次短码配对没有被降级实现。候选审查与阻塞理由见 ADR 0004；双机互操作、平台构建和全量回归
中的平台部分仍需继续执行后补入本节。

## V12-08 网络引导第一阶段证据

2026-09-24 在 macOS/FVM Flutter 3.47.5 环境执行：

```text
fvm flutter test test/platform/platform_network_gateway_test.dart --reporter expanded
结果：7 tests passed

fvm flutter analyze
结果：No issues found

fvm flutter test --reporter compact
结果：1344 tests passed

cd android && ./gradlew :app:compileDebugKotlin -x :app:compileFlutterBuildDebug
结果：BUILD SUCCESSFUL；LocalOnlyHotspot/WifiNetworkSpecifier 代码编译通过
```

Windows C++ 未在本机编译，后续 PR CI release 构建已通过；Android 热点、入网系统确认、无互联网
路由、指定 Network 的 HTTPS socket 和资源释放未在真机执行，不能视为热点传输验收。

## V12-06 BLE 控制通道自动化证据

2026-09-24 在 macOS/FVM Flutter 3.47.5 环境执行：

```text
fvm dart format --output=none --set-exit-if-changed .
结果：212 files，0 changed

fvm flutter analyze
结果：No issues found

fvm flutter test test/core/network/ble_control_frame_test.dart \
  test/platform/ble_control_gateway_test.dart --reporter compact
结果：14 tests passed

fvm flutter test --reporter compact
结果：1322 tests passed

./gradlew :app:compileDebugKotlin -x :app:compileFlutterBuildDebug
首次结果：下载 org.ow2.asm:asm-commons:9.7 时 Maven TLS 握手中断，未开始项目源码编译
重试结果：BUILD SUCCESSFUL；主应用与 bluetooth_low_energy_android 6.2.1 编译通过，存在上游弃用警告

fvm flutter build ios --simulator
结果：成功，生成 build/ios/iphonesimulator/Runner.app
```

未执行 Android/Windows 双机 BLE、真实 MTU、权限拒绝/恢复、适配器关闭、后台切换和断线重连。
Windows 插件已由后续 PR CI 编译；模拟网关只验证应用边界与生命周期，不能作为无线互操作证据。

## 证据规则

实机记录至少包含设备型号、系统版本、网络条件、NearSend 提交号、操作步骤、结果和必要的
脱敏日志。不得记录配对秘密、热点密码、私钥、恢复凭证或用户文件内容。
