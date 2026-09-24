# ADR 0001：V12-00 能力验证基线

状态：进行中

日期：2026-09-24

## 背景

NearSend 1.2 需要系统目录、BLE/mDNS 发现、稳定身份、标准安全配对、Android 本地热点和
Windows 入网能力。插件名称或平台 API 文档不能替代目标设备验证，因此每条能力在冻结接口和
依赖前分别记录候选、已验证结果和阻塞。

## 已确认基线

- 项目和 CI 固定 Flutter 3.47.5 / Dart 3.13.4；升级分支提交 `.fvmrc`，不修改全局 SDK。
- 数据库当前为 schema v7，设置表只保存非秘密字符串；peer 表保存指纹与授权状态，不保存令牌和私钥。
- Android SAF 目录树选择、持久授权复查、目录枚举、目标创建和有界流式导出已完成代码级实现；
  MethodChannel 契约测试和 Kotlin 编译通过。真机重启、撤权与不同 DocumentsProvider 行为尚未验证，
  因此不冻结为实机通过结论。
- 当前节点每次启动生成 TLS 身份。稳定身份和私钥存储未完成，不能把现有重启行为描述为可信历史。
- 现有 HTTPS、指纹 pin、一次性配对令牌、分块校验与 committed 块权威继续复用。

## 工具链决定

保留锁定的 `sqlite3 3.6.0`。默认 Native Assets 会从该包的不可变 GitHub Release 下载并校验
预编译库；当前 macOS 环境的下载发生 TLS 握手中断。`sqlite3 3.6.0` 官方 hook 支持按目标系统
选择来源，因此仅在 macOS 使用系统 `libsqlite3`，其他平台继续使用默认锁定二进制。这样不会为了
本机网络故障降级依赖，也不会要求 Android/Windows 改用能力不同的系统 SQLite。

## 尚未冻结的候选

| 能力 | 候选 | 当前结论 |
|---|---|---|
| mDNS | `bonsoir 7.1.5` | 依赖、许可、API 和代码级平台构建已验证并固定；双机和隔离网络实测待补，见 ADR 0002 |
| BLE | `bluetooth_low_energy 6.2.1` | 许可、SDK、API、帧边界和代码级适配已固定；Android/Windows 双机 GATT、权限和生命周期实测待补，见 ADR 0003 |
| 短码配对 | RFC 9382 SPAKE2 / RFC 9383 SPAKE2+ 的成熟实现 | 尚未找到完成许可证、向量和跨平台验证的实现；禁止自制替代 |
| Android 热点 | `LocalOnlyHotspot` + reservation 生命周期 | 需要真机 API/权限/路由验证 |
| Windows 入网 | Native Wi-Fi API + WLAN 事件 | 当前主机不能验证 |
| 稳定秘密 | 平台安全存储或项目内原生安全存储桥接 | 需验证 TLS 私钥格式、失效和迁移 |

每一项形成最小可运行结果后再补充本 ADR 或新增独立 ADR。失败的候选不会以空实现或固定成功返回值
进入产品代码。
