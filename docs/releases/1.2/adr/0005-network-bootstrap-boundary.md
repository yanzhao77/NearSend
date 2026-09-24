# ADR 0005：热点与网络引导边界

状态：部分接受，传输绑定受阻

日期：2026-09-24

## 决策

应用层先对最多 8 个候选执行有 3 秒上限的认证端点探测。只有所有候选均失败时才考虑建立新网络；
SSID 相同、ping 成功、BLE 已连接都不是可达或可信结论。

平台网关使用短期 lease 管理系统资源：

- Android API 26+ 使用 `LocalOnlyHotspot`，保留系统 reservation，并只接受系统实际返回的受保护
  SSID、密码和安全类型。Android API 29+ 入网使用 `WifiNetworkSpecifier` 和系统确认 UI，保留
  `NetworkCallback`，30 秒超时。
- 热点密码只存在于原生/Dart 内存，没有序列化、日志或 `toString` 输出。它只能在已认证控制通道或
  用户主动展示的短期二维码中传递。
- lease ID 必须精确匹配才能释放；Activity 销毁会关闭 reservation 和 network request。
- Android 不调用 `bindProcessToNetwork`。进程级绑定会影响更新、反馈和其他连接，且当前未验证
  Flutter `dart:io` HTTPS socket 对指定 Android `Network` 的行为。
- Windows 当前只报告自动热点/入网不可用并可打开系统 Wi-Fi 设置。Native Wi-Fi 的 WLAN 事件、
  NearSend 临时 profile 所有权、恢复旧网络和清理尚未在 Windows 主机验证，不能先返回成功。

## 当前结论

Android 原生代码与 MethodChannel 契约已编译/测试，但没有真机热点、系统确认、无互联网路由或释放
证据。更重要的是，`WifiNetworkSpecifier` 返回的 `networkHandle` 尚无经过验证的传输 socket 绑定，
所以本阶段不能声称不同 Wi-Fi 或无路由器时已经能传文件。下一步需要在真机验证原生 socket factory
或限定范围的网络绑定方案，再把认证 HTTPS 探测和传输绑定到同一个 lease。
