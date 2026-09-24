# ADR 0002：mDNS 发现适配与未认证边界

状态：已采纳，平台实机验证进行中

日期：2026-09-24

## 决策

NearSend 使用固定版本 `bonsoir 7.1.5` 实现 `_nearsend._tcp` 的 DNS-SD 发布与浏览。该版本要求
Dart >=3.8、Flutter >=3.44，兼容项目固定的 Dart 3.13.4 / Flutter 3.47.5；主包和 Android、
Darwin、Windows、Linux 分包均为 MIT 许可。pub.dev 发布于 2026-08-11，Android 分包使用 NSD，
Windows 分包使用 WinDNS，当前仍有维护活动。

依赖只负责系统 mDNS/DNS-SD API，不参与身份认证、TLS 校验、配对或文件传输。依赖及传递依赖
版本和摘要由 `pubspec.lock` 固定；不使用插件调试日志输出发现内容。

## 公开记录

发布名称为 `NearSend-` 加临时实例 UUID 的前 8 位，不广播用户设备名。TXT 只包含：

| 键 | 内容 |
| --- | --- |
| `maj` | 协议 major 的规范十进制 |
| `min` | 协议 minor 的规范十进制 |
| `iid` | 当前短期会话的规范 UUID |
| `caps` | `discovery.mdns.v1` |

TXT 不包含长期设备 ID、公钥、TLS 指纹、配对/访问令牌、热点凭据、文件名、路径或任务信息。
`iid` 只用于发现期去重和抑制本机回环，不是可信设备身份。

## 输入与生命周期

- 发现记录始终标记为未认证。名称、TXT、地址和端口只有完成后续身份认证与 TLS 绑定后才能使用。
- 只接受规范版本整数和 UUID；能力最多 16 项，地址最多 16 个。无可用解析地址的记录不进入候选。
- 过滤 loopback、unspecified、multicast 和保留 IPv4 地址；保留带合法 zone 的 IPv6 link-local 地址。
- HTTPS 节点完成监听并生成短期会话后才发布。停止时先撤销浏览和广播，再关闭 HTTPS 节点。
- 服务更新替换同名候选，服务丢失立即移除 mDNS 来源。mDNS 失败不关闭手动连接，错误以结构化状态上报。
- 当前插件事件可处理同一接口内的更新与丢失；主动网络切换后的节点地址重建留给 V12-10/V12-11
  的就绪状态机和生命周期协调，不在本阶段伪造完成。

## 平台配置与限制

- Android 插件清单声明 `INTERNET` 和 `CHANGE_WIFI_MULTICAST_STATE`；Kotlin 编译是代码级证据，
  仍需 Android 真机验证多播锁、后台和不同 AP 行为。
- iOS 保留 `NSLocalNetworkUsageDescription`，并声明 `NSBonjourServices = _nearsend._tcp`。
- Windows 实现随 `bonsoir_windows 7.3.0` 使用 WinDNS；当前 macOS 主机不能替代 Windows 编译和
  防火墙/多网卡实测。
- mDNS 不跨路由器和隔离网络。该失败不代表 BLE 或二维码不可用，也不能据此显示历史设备在线。

## 被否决方案

- 不手写 DNS 报文解析器：跨平台组播、IPv6、接口变化和资源释放已有成熟系统 API 与插件实现。
- 不把配对载荷、TLS pin 或令牌放进 TXT：广播可被被动收集，且发现不能替代认证。
- 不使用设备名或 IP 作为持久身份：两者可变且可伪造。
