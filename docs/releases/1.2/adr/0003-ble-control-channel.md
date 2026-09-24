# ADR 0003：BLE 发现与有界控制通道

状态：已采纳，平台实机验证进行中

日期：2026-09-24

## 决策

NearSend 固定 `bluetooth_low_energy 6.2.1` 作为 Android/Windows BLE central/peripheral 适配层。
主包及 Android、Darwin、Windows、Linux 分包使用 MIT 许可；版本发布于 2026-01-17，要求
Dart >=3.9.2，与项目固定 Dart 3.13.4 / Flutter 3.47.5 兼容。仓库未归档，2026 年仍有发布活动。
依赖和传递依赖版本及摘要由 `pubspec.lock` 固定。

插件只封装扫描、广告、GATT、MTU 和权限 API。NearSend 自己定义并测试固定有界的控制帧，见
[`ble-control-v1.md`](../../../protocol/ble-control-v1.md)。BLE 不承载文件内容，不产生可信身份，也不
替代 TLS pin、任务授权、接收确认、哈希或 committed 块恢复规则。

## 角色与生命周期

- Android 和 Windows 同时具备 central/peripheral 代码路径。central 通过 service data 发现候选，
  连接后以 write-with-response 发送；peripheral 通过 notification/indication 返回。BLE 角色与文件
  发送方向相互独立。
- 广告不使用设备名。固定 service UUID 的 10 字节 service data 只含格式版本、协议版本、保留位和
  48 位临时实例标签；标签不是长期身份或认证证明。
- 启动要求平台报告蓝牙已开启且已授权，不返回固定成功。Android 权限只在调用授权入口时申请；
  Android 12+ 使用 scan/connect/advertise，旧版本按实际系统使用 Bluetooth 和位置权限。
- 停止顺序为停止扫描、停止广告、断开 central 连接、移除 GATT service、取消事件订阅。单个资源
  释放失败不跳过其余清理。
- Windows peripheral 不提供连接状态流，使用 characteristic 订阅状态管理反向通知；Android 同时
  监听真实连接状态。该差异限制在平台适配层。

## 安全与资源边界

- 广告和 GATT 对端均按未认证输入处理。只有 V12-07 的双向身份认证和密钥确认成功后，才能把设备
  标记为可信或就绪。
- 逻辑消息最大 16 KiB，帧最大 512 字节，一个对端只允许一条在途消息，最多保留 16 个对端，15 秒
  超时。重复、乱序、重放、截断、坏版本和不一致长度失败关闭。
- 原始控制载荷不进入日志。长期身份、公钥证明、令牌和热点凭据不进入广告或普通 SQLite 字段。
- Android `neverForLocation` 与本产品用途一致，但仍需目标系统验证扫描结果不会因设备类型被过滤。

## 已验证与未验证

当前 macOS/FVM 环境已完成依赖解析、Dart 编译、帧/重组/网关生命周期测试、全量 Flutter 回归、
Android 主应用及 BLE 插件 Kotlin 编译和 iOS Simulator 构建。Android 首次尝试在 Maven TLS 握手
中断，重试下载成功后完成编译；插件对旧 Android GATT API 有弃用警告，并仍应用旧 Kotlin Gradle
Plugin，升级到 Gradle 10 或后续 Flutter 前必须复核。当前无 Windows 主机、Android/Windows BLE
双机或 iOS 真机，因此以下不能标记通过：

- Android 广告、权限拒绝/恢复、MTU、后台切换及不同芯片组行为；
- Windows 编译、扫描/连接、notification、适配器关闭和无 peripheral 能力降级；
- 不同 Wi-Fi 下 Android/Windows 双向控制消息；
- iOS BLE 生产适配。Info.plist 已加入用途说明，但 V12-06 的默认适配器有意只开放已审查的
  Android/Windows 路径。

## 被否决方案

- 不用 BLE 传文件：吞吐、后台、MTU 和可靠性不适合作为大文件数据面，也会绕开现有安全传输核心。
- 不把广告名、IP 或短实例标签当设备身份：均可变化、碰撞或伪造。
- 不自行实现蓝牙协议栈或加密：系统 BLE API 由已审查插件封装；应用认证仍等待成熟 PAKE 选型。
