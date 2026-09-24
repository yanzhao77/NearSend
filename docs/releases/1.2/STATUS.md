# NearSend 1.2 开发状态

更新日期：2026-09-24

开发分支：`feat/v1.2-upgrade`

基线：`master` / `d6a79fa44a820f7396dff2b3fcb2ba2c8278468a`

本文件记录实际实现、验证和阻塞。任务状态只按可核对证据更新；代码存在、模拟事件或 UI
可见不等于平台能力和实机流程已经通过。

## 工具链与工作区

- 使用 FVM Flutter `3.47.5` / Dart `3.13.4`，与 CI 固定版本一致。
- 开发位于独立 worktree `/Users/sjw/Documents/GitHub/NearSend-v1.2`。
- 主工作区的 `.fvmrc`、依赖调整和本地 LAN 测试是用户未提交内容，未复制、覆盖或删除。
- `flutter analyze` 基线通过。
- `flutter test` 首次在 macOS Native Assets 下载 SQLite 动态库时遇到 TLS 握手中断。项目保留
  `sqlite3 3.6.0`，仅将 macOS hook 配置为使用系统 SQLite；Android、Windows 和其他平台继续
  使用锁定依赖的默认二进制。调整后完整测试 1256 项全部通过。
- 当前数据库权威版本是 schema v9；v7 包含只保存非机密值的 `app_settings` 表，v8 新增接收
  输出计划，v9 新增公开本机身份元数据和 peer 历史字段。位置引用的 v1 格式仍在设置表内按值迁移。

## 任务状态

| 任务 | 状态 | 当前结果 | 下一步 |
|---|---|---|---|
| V12-00 基线与能力验证 | 进行中 | 已核对 Flutter、Dart、schema v7、协议草案和平台边界；mDNS 与 BLE 已完成依赖/许可/API、边界测试和当前环境代码级验证 | 继续验证 BLE 真机互操作、PAKE、热点和网络绑定候选 |
| V12-01 系统位置与迁移 | 进行中 | 已实现严格版本化 `StorageLocationRef`、旧字符串值迁移、畸形值保留修复状态、Android 系统目录树选择/持久授权复查/有界 SAF 导出，以及 Windows `IFileDialog`/Known Folder/空间查询；28 项定向测试、1267 项全量测试、Android Kotlin 编译和 Windows CI release 构建通过 | Android 真机验证重启后写入/撤权；Windows 主机实测目录选择与写入 |
| V12-02 接收输出计划 | 当前环境完成 | schema v8 持久化冻结原名、本地改名、目标引用、冲突策略和导出状态；两个真实 TLS 方向均在接受前建计划，改名不改变清单/哈希，1275 项全量测试通过 | Android/Windows 实机验证权限失效、崩溃重试、同名冲突和平台句柄重开 |
| V12-03 设置与确认 UI | 当前环境完成 | 默认目录选择先复查权限再持久化；单/多文件在一次弹框中确认位置与本地名称；取消、非法名、撤权和空间不足均不会接受；两个真实 TLS 方向已从确认 UI 保存并校验文件 | Android/Windows 实机验证系统选择器、重启授权、撤权修复与多文件保存 |
| V12-04 稳定身份与历史 | 进行中 | P-256 长期设备身份与 TLS 身份通过 Android Keystore/Windows DPAPI 安全载荷持久化；schema v9 只存公开元数据；已知设备挑战已将身份、就绪状态和 TLS pin 绑定并可更新最近实时验证；Windows CI release 构建通过 | Android/Windows 重启、DPAPI 持久化和双向挑战实测 |
| V12-05 mDNS 发现 | 进行中 | 固定 `bonsoir 7.1.5`；实现最小 TXT、严格候选解析、发布/浏览/更新/丢失/停止生命周期；Android Kotlin 与 iOS Simulator 构建通过 | Android/Windows 同网双机发现并完成身份认证；验证隔离网络与网络切换清理 |
| V12-06 BLE 控制通道 | 进行中 | 固定 `bluetooth_low_energy 6.2.1`；实现无设备名广告、Android/Windows 双角色 GATT、16 KiB 有界分片、严格重组和资源释放；14 项定向测试、1322 项全量测试及 Windows CI release 构建通过 | Android/Windows 双机验证不同 Wi-Fi 下双向控制消息、权限、MTU、掉线和后台生命周期 |
| V12-07 统一安全配对 | 部分完成，PAKE 受阻 | 已实现已授权设备 P-256 新鲜挑战、角色/版本/ready/TLS pin 绑定、30 秒有效期、重放/撤销/身份替换失败关闭；现有 QR 指纹与一次性令牌路径保留 | 选择满足审计、向量和 Android/Windows/iOS 支持的成熟 PAKE；双机验证双向挑战 |
| V12-08 热点与数据通道 | 部分完成，路由绑定受阻 | 已实现认证端点优先的有界网络选择、Android LocalOnlyHotspot/系统确认入网 lease 与资源释放、Windows 系统设置回退；凭据不持久化/不输出 | Android 真机验证热点与指定 Network socket；Windows 主机验证 Native Wi-Fi 事件/profile/恢复后再开放自动加入 |
| V12-09 二维码入口 | 进行中 | 严格 `nearsend-bootstrap` v1、旧码兼容、真实会话二维码、移动离线摄像头、Windows 有界图片导入及扫码后系统入网→TLS pin 配对协调已实现；Android 与 Windows CI 构建通过 | 摄像头/导图/热点二维码实测；向用户呈现平台入网错误 |
| V12-10 首页雷达与在线历史 | 部分完成 | 默认关闭的就绪状态机已真实启停 mDNS/BLE；首页合并历史、mDNS、BLE 候选，只有新鲜已授权证明显示绿色状态 | 将已知设备挑战接入生产 BLE/mDNS 控制链路；完成首次 PAKE、候选点击配对和双机实测 |
| V12-11 系统打开与异常收尾 | 代码与当前环境自动化完成，平台交互验证受阻 | 保存结果和任务详情只在真实最终句柄存在时提供系统打开/定位；Android 使用 SAF/FileProvider，Windows 使用 Shell API；后台关闭雷达，扫码、BLE、mDNS、热点/入网 lease 均有收尾路径；1369 项全量测试及 Android/Windows CI 构建通过 | Android 真机验证 SAF/FileProvider；Windows 主机实测 Shell 动作；补后台切换、权限撤销和热点清理实机证据 |
| V12-12 回归与发布准备 | 当前环境完成，目标设备验收受阻 | 格式、分析、1369 项测试、Android debug/release、Windows release、iOS Simulator、文档链接、敏感信息和 CI 工作流检查通过；README、状态、验收和台账已收口 | Android/Windows 双机执行剩余矩阵；补 PAKE、指定网络绑定、热点和大文件证据后才能发布 |

## 当前环境限制

- 当前主机为 macOS；Windows release 已由 GitHub Actions 编译，但 CI 不能代替 Windows 10/11 BLE、WLAN、选择器和 Shell 交互实测。
- 尚未取得本轮 Android 与 Windows 双机、不同 Wi-Fi、无路由器或热点传输证据。
- iOS、Windows 的新增平台能力不能在当前环境标记通过。
- Android debug APK 本轮首次 Maven 下载握手中断，Flutter 自动重试后构建成功；这只证明可构建，
  不替代安装、SAF、BLE、热点、指定 Network 和双机传输真机验证。

## V12-01 阶段记录

- `StorageLocationRef` 只持久化版本、类型、不透明引用和展示名称；运行时权限状态不持久化为承诺。
- 旧的裸目录字符串在读取时迁移为 v1 JSON。无法解析的 JSON 原值保留，设置页要求重新选择，
  不静默删除用户设置。
- Android 使用 `ACTION_OPEN_DOCUMENT_TREE` 和系统实际返回的读写授权调用
  `takePersistableUriPermission`；每次枚举或创建目标前重新核对持久授权。
- SAF 导出从应用私有暂存块按序以 256 KiB 有界缓冲写入。完成后才结束写入；失败只清理该次
  创建且尚未提交的文档，已保存文件没有删除入口。文档提供方导出明确报告为非原子。
- Android 真机上的提供方差异、应用重启后的授权延续、用户撤权、云提供方离线状态和系统自动改名
  仍需人工验证。Windows 原生适配已通过 CI release 编译，但尚未实测，因此 V12-01 不标记完成。

## V12-02 阶段记录

- schema v8 新增 `receive_output_plans`，本地名称和目标位置与冻结 manifest 分开保存；v7→v8
  迁移保留设置行并有自动化覆盖。
- 客户端接收在 `POST /decision` 前以任务绑定会话分页读取 files 元数据并持久化输出计划；服务端
  接收在本地 `acceptLocally` 前完成同一动作。顺序测试在仓储写入时断言授权尚未接受且 committed
  字节为 0。
- 导出只从持久化计划读取名称、位置和冲突策略。Android 保存后记录文档 URI，本地文件系统记录
  实际目标路径；导出失败标为 `failed` 并保留暂存，重试复用同一计划。
- 自动化覆盖中文改名、冻结路径不变、自动安全重命名、非法/保留名称、迁移、目标句柄、拒绝无
  内容落盘和双向真实 TLS 流程。真实 Android 文档提供方与 Windows 文件系统的撤权/崩溃窗口仍
  未验证，不据此标记平台验收通过。

## V12-03 阶段记录

- 接收页先读取已绑定任务的冻结文件元数据，再显示一个单/多文件确认弹框。每个文件可单独修改
  本地输出名；映射按 `fileId` 传给 V12-02 输出计划，发送方原路径、清单摘要和块哈希不变。
- 默认位置与单次位置全程使用 `StorageLocationRef`。Android SAF URI 只作为不透明引用传递，界面
  仅显示平台提供的 `displayName`；确认前重新验证目录权限，`denied`/`unavailable` 阻止接受。
- 设置页选择目录后先验证权限再持久化。取消选择、选择器异常、已保存权限撤销和畸形旧值均保留
  原设置并提供修复入口，不把未验证位置保存成可用默认值。
- 服务端推送在最终确认的位置上重新执行空间预检；已知不足阻止接受，未知空间需要独立明确确认。
  两个真实 TLS 应用测试均经过新弹框后完成整文件校验和保存。
- `flutter analyze` 通过；设置与接收页 18 项定向组件测试通过；全量 1285 项测试通过。Android/
  Windows 系统选择器、应用重启后的授权延续和真实文档提供方撤权仍需目标设备验证。

## V12-04 第一阶段记录

- 新增长期 P-256 设备身份，与 TLS leaf/key 分开建模。Android 使用 Keystore AES-GCM 包装一个
  应用私有密文载荷；Windows 使用当前用户作用域 DPAPI、刷盘临时文件和原子替换。私钥不进入
  SQLite、日志或诊断文本。
- schema v9 的 `local_identity` 仅保存 device ID、公钥、平台安全存储引用和格式版本。安全存储
  身份与数据库公开元数据不匹配时拒绝启动；已存在身份元数据但安全身份缺失或损坏时也不静默
  重建。pre-v9 数据库没有身份元数据，可在升级时建立首个稳定身份，避免把正常升级误判为身份丢失。
- `peers` 保留原有指纹变化阻断与撤销记录，并增加公钥、平台、信任状态、配对时间和最近实时验证
  时间。只有已授权且指纹匹配的挑战结果能更新 `last_verified_at`，广告或同名匹配不能调用成功。
- Android Kotlin 编译通过；身份、迁移、旧数据库升级、仓储、节点生命周期和 MethodChannel
  定向测试通过；全量 1301 项测试通过，静态分析无问题。Windows 原生代码已通过 CI release 编译；
  长期身份尚未绑定到双向认证，故 V12-04
  保持进行中，不能据此点亮在线状态或自动信任历史设备。

## V12-05 mDNS 阶段记录

- `bonsoir 7.1.5` 与项目固定工具链兼容，MIT 许可，依赖及传递依赖摘要写入锁文件。Android 使用
  NSD，Windows 使用 WinDNS，Darwin 使用 Bonjour；依赖只处理系统发现，不参与身份或 TLS 信任。
- `_nearsend._tcp` TXT 仅发布协议 major/minor、短期实例 UUID 和 `discovery.mdns.v1`。不发布设备
  名称、长期身份、公钥、TLS pin、令牌、热点凭据、文件或路径。发现结果始终是未认证候选。
- 解析限制能力/地址数量，拒绝畸形版本和 UUID，过滤本机回环、未指定及多播地址，保留合法 IPv6
  zone。HTTPS 节点监听并生成配对会话后才发布；停止时先撤销浏览和广播。
- 12 项 mDNS/节点生命周期定向测试及 1308 项全量测试通过；Android 主应用和插件 Kotlin 编译通过；iOS Simulator
  构建通过。iOS 设备无签名构建仍被 Development Team/Provisioning 配置阻断；Android APK 仍被
  sqlite3 原生库下载 TLS 握手中断阻塞；后续 Android 与 Windows CI 构建均通过。Android/Windows 同网双机发现尚未执行。

## V12-06 BLE 控制通道阶段记录

- 固定并审查 `bluetooth_low_energy 6.2.1`：MIT 许可、兼容 Dart 3.13.4 / Flutter 3.47.5，提供
  Android/Windows central 与 peripheral、GATT、MTU、write 和 notification API。平台插件只负责
  系统能力，不参与身份认证或文件传输。
- 广告不包含设备名、身份、公钥、TLS pin 或秘密。固定 service UUID 的 service data 仅含格式/
  协议版本和 48 位临时实例标签；发现记录始终是未认证候选。
- 控制帧固定 16 字节头，逻辑消息上限 16 KiB、帧上限 512 字节、15 秒超时、每对端一个在途重组、
  总计 16 个对端。自动化覆盖默认 20 字节帧、最大消息、截断、坏版本、重复、乱序、重放和超时。
- 两端都可作为 central/peripheral，GATT 角色不决定后续文件方向。停止时撤销扫描、广告、连接、
  service 和订阅。V12-07 认证完成前，任何 BLE 消息都不能点亮可信/就绪状态。
- 格式检查、静态分析、14 项定向测试及 1322 项全量测试通过。Android Gradle 首次尝试因 Maven
  TLS 中断失败，重试后主应用和 BLE 插件 Kotlin 编译通过；iOS Simulator 构建通过。插件报告旧
  Android GATT API 和 Kotlin Gradle Plugin 弃用警告。Windows 插件已通过 CI release 编译；
  Android/Windows 双机控制消息、权限、MTU、适配器关闭、后台和断线恢复尚未执行，因此 V12-06 保持进行中。

## V12-07 已知设备认证阶段记录

- 长期 P-256 身份现在可签署规范 `NSPEER1` transcript。签名覆盖协议版本、事务 UUID、verifier/
  prover 角色、32 字节挑战、ready 和当前 TLS leaf 指纹；使用固定 64 字节 low-S ECDSA
  P-256/SHA-256，严格解析规范 SPKI/PKCS#8 DER。
- 挑战 30 秒过期、一次消费、最多 16 个待处理项。成功、失败、过期和撤销后均不可重放；已授权
  公钥必须逐字节匹配。只有成功验证能更新 `last_verified_at` 和该长期身份绑定的 TLS pin。
- 自动化覆盖 proof 重放、ready/TLS pin 篡改、身份替换、角色反射、签发后撤销、过期、上限回收和
  畸形/超限 wire 输入。广告、设备名、IP 和 mDNS 记录没有更新在线状态的入口。
- PAKE 调研拒绝 `spake2plus 1.0.2`（仅 Linux/macOS、外部 OpenSSL 3 FFI）和 `dsrp 0.5.5`
  （未审计 0.x、发布包缺测试、自选 safe prime 风险）。首次短码配对继续受阻，不使用自制替代；
  现有高熵二维码一次性令牌路径保留。
- 定向安全测试 42 项、全量测试 1337 项和静态分析通过。Android/Windows 双向认证与平台构建仍
  缺少对应环境；当前没有双机实测证据。

## V12-08 网络引导第一阶段记录

- 网络选择器最多处理 8 个候选，每个认证端点探测最多 3 秒。只有实际 TLS/身份认证探测成功才复用
  现有网络；SSID、ping 或 BLE 连接不构成成功。
- Android API 26+ 使用系统 `LocalOnlyHotspot` 回调和 reservation，API 29+ 使用
  `WifiNetworkSpecifier`、系统确认及 `NetworkCallback`。权限按系统版本在用户触发时请求，热点和
  入网 lease 在显式释放或 Activity 销毁时回收。
- SSID/密码来自系统真实回调，密码只留在内存，`toString` 和错误不包含凭据。开放热点或缺少凭据
  失败关闭；不预设热点地址或网络可达。
- Android 编译通过，Dart 网关/选择器 7 项及全量 1344 项测试通过，并拒绝公网、回环和畸形候选。未调用
  `bindProcessToNetwork`；返回的
  `networkHandle` 尚未与 Flutter HTTPS socket 绑定并完成真机验证，因此无路由器真实传输仍受阻。
- Windows 当前明确报告自动加入不支持并打开系统 Wi-Fi 设置。Native Wi-Fi 的 WLAN 完成事件、
  临时 profile 所有权、旧网络恢复和清理必须在 Windows 环境验证后才能开放。

## V12-09 Bootstrap 载荷阶段记录

- 扫描入口先用项目严格 JSON 扫描器拒绝重复键、非法结构和超过 4096 字节输入，再按 `kind` 分发；
  旧 `lft-pair` 继续使用原解析器，未知类型不降级。
- 新载荷绑定长期 P-256 公钥及其 device ID、现有 TLS leaf pin、协议版本、会话 UUID、32 字节一次性
  令牌和固定邀请角色。声明有效期最多 120 秒，服务端未消费会话仍是最终权威。
- `networkBootstrap` 必须携带系统实际建立后的 WPA2/WPA3 SSID/密码；已有网络模式必须没有热点
  凭据。热点密码不会出现在对象文本中，载荷本身不得持久化或记录。
- 7 项载荷测试通过。平台实机流程尚未验证，V12-09 不能标记完成。
- 已固定并审查 `qr_flutter 4.1.0`、`mobile_scanner 7.1.3`、`zxing2 0.2.4`、`image 4.10.1`
  和测试用 `qr 3.0.2`。二维码显示已接入真实 `lft-pair` 会话；移动扫码只接受单个严格合法值；
  Windows 系统图片导入限制 16 MiB，解码限制 1600 万像素并在 isolate 执行。
- QR PNG 往返与异常输入 2 项、连接页 24 项及全量 1353 项测试通过；iOS Simulator 构建通过。Android 编译连续
  两次因 Maven TLS 下载 Kotlin 1.8 工件失败；后续 Android 与 Windows CI 构建均通过。扫码结果到
  热点入网/配对的平台纵向流程仍未实测，因此平台入口不标记完成。
- 粘贴、摄像头和图片导入共用 `ScannedPairingPayload`。热点码先调用系统 Wi-Fi 入网并保留 lease，
  再把嵌套原始载荷交给既有 `PeerSession` 执行 TLS pin 和一次性令牌握手；失败或应用销毁释放 lease。
  连接页 25 项测试覆盖 bootstrap 不误走旧回调。平台入网错误的用户可见分类仍需完善。

## V12-10 首页雷达阶段记录

- 应用每次启动默认未就绪。HTTPS 接收节点继续运行，但 mDNS 广播/浏览与 BLE 广播/扫描只有用户
  开启雷达后才启动；关闭按顺序停止两类资源，并清除未认证候选和内存中的在线证明。
- 就绪状态区分 `off`、`starting`、`ready`、`stopping` 和 `error`，启动期间禁用重复切换并显示
  真实失败说明。BLE 权限只在用户开启时请求，拒绝不会关闭手动连接和二维码入口。
- 历史、mDNS 与 BLE 使用不同事实来源。mDNS/BLE 广告始终显示为“候选”且没有状态灯；只有数据库
  中仍为 authorized 的长期身份完成新鲜 `VerifiedPeerSession(ready=true)` 后才显示绿色状态，证明
  过期、关闭就绪或撤销授权后立即/按期熄灭。设备名称和地址不参与身份判断。
- 定向 22 项组件/控制器/节点/壳测试、静态分析及 `test/app/app_test.dart` 6 项真实 TLS 应用流程
  通过。首次全量回归在首页布局修正前出现 4 个主操作被推离首屏的失败并被人工中断；修正布局和
  测试滚动后完整回归 1361 项通过。
- 已知设备挑战目前只有安全实现和受控 `recordVerified` 入口，尚未在生产 BLE/mDNS 控制消息上交换；
  未知候选也仍受成熟 PAKE 缺失阻塞。因此候选点击仅进入现有连接页，V12-10 不标记完成。

## V12-11 系统打开与异常收尾阶段记录

- 接收流程保留平台导出返回的 `createdTargetRef`，并与安全展示名分开建模。结果页和任务详情只在
  SQLite `receive_output_plans.final_target_ref` 或本次真实导出结果存在时提供“打开”和“显示位置”，
  没有句柄时不显示不可执行动作。MethodChannel 拒绝空白、控制字符及超过 8192 UTF-8 字节的引用，
  错误只返回结构化状态，不在提示或对象文本中输出 URI/路径。
- Android 对 SAF `content://` URI 复查可读权限后用 `ACTION_VIEW`；应用私有默认接收目录只通过
  非导出的 `FileProvider` 暴露 `files/received/` 子目录，不暴露整个 `filesDir`，也不生成
  `file://` URI。SAF 文档尝试交给系统显示目录；应用私有文件无法定位时诚实报告不支持。
- Windows 只接受实际存在的普通文件，使用 `ShellExecuteW` 打开，并使用
  `SHParseDisplayName`/`SHOpenFolderAndSelectItems` 定位；不拼接 shell 命令。该 C++ 路径已通过
  Windows CI release 编译，但尚未交互实测。
- 应用进入非前台状态时撤销雷达期望并停止 mDNS/BLE；异步停止失败不阻断另一资源的清理，也不会
  让切换队列永久失败。移动扫码控制器改为页面生命周期内单例并在销毁时释放。Activity 销毁继续
  关闭热点 reservation、入网 callback 和待处理权限请求；应用销毁继续释放入网 lease。
- `fvm dart format --output=none --set-exit-if-changed .`、`fvm flutter analyze` 通过；文件动作、
  接收结果、任务详情、SQLite 最终句柄、双向接收流程和后台雷达定向测试通过；完整回归 1369 项通过。
- Android Kotlin 首次重试在 `mobile_scanner` 的 Maven 依赖下载阶段因 TLS 握手中断；V12-12 的
  `flutter build apk --debug` 自动重试后成功并产出 APK。Windows Shell 代码已通过 CI release 编译；
  Android/Windows 系统动作、撤权和后台切换实测均未执行，因此 V12-11 不标记为平台验收完成。

## V12-12 回归与发布准备阶段记录

- 使用 FVM Flutter 3.47.5 / Dart 3.13.4 执行全仓格式检查、静态分析和完整测试；226 个 Dart 文件
  无格式差异，静态分析无问题，1369 项测试通过。Android debug APK 在首次 Maven TLS 下载失败后
  由 Flutter 自动重试成功，iOS Simulator 构建成功。
- macOS desktop 未在仓库配置；SDK 下载重试成功后 Flutter 明确报告 `No macOS desktop project
  configured`，因此不将其记为应用构建失败或通过。Windows release 由 PR #68 的 CI run
  `35961651508` 编译成功；该证据只覆盖编译和链接，不覆盖平台交互。
- Markdown 严格链接检查覆盖 104 个跟踪文件和 548 个链接；敏感信息扫描覆盖 506 个跟踪文件；
  CI 工作流检查确认 Action SHA 固定、无 `continue-on-error`、只读权限和 Flutter 版本一致。
- S0 Python 协议/存储 21 项通过；TLS 测试类因 Xcode Python 3.9 链接 LibreSSL 2.8.3 且不支持
  TLS 1.3 而无法初始化。未降低 TLS 要求，也未把 21 项写成完整 24 项通过。
- 当前环境证据归档在
  `docs/testing/evidence/2026-09-24/v1.2-upgrade/summary.md`。未执行的 Android/Windows 双机、
  不同 Wi-Fi、无路由热点、大文件、权限撤销、IP 改变、身份伪装和后台资源矩阵继续保持未通过。
- 本分支只准备实现和证据，不合并 `master`、不创建正式版本、不发布 Release。

## 人工重点复核

- 安全配对：PAKE 选型、身份绑定、TLS pin 连续性、撤销与安全存储。
- 文件写入：SAF/Windows 句柄、流式写入、同步、导出提交、冲突和取消后的清理范围。
- 数据库迁移：旧设置、peer、未完成配对事务和输出计划的幂等恢复。
- 网络：Android 热点 reservation、Windows 临时配置、网卡绑定、资源释放与原网络恢复。
