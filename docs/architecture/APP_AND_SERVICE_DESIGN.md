# NearSend 应用与端侧服务设计

## 1. 设计说明

本项目没有传统云端“前台 + 后台”。所谓前台是 Flutter 用户界面和应用用例；所谓后台是每台设备进程内的本地 HTTPS 服务、传输引擎、SQLite 和平台适配。两端运行同一套业务规则，可因连接角色分别作为本地 API server 或 client。

## 2. 推荐代码结构

```text
lib/
├── app/                 # 启动、路由、主题、依赖装配
├── features/
│   ├── home/
│   ├── pairing/
│   ├── send/
│   ├── receive/
│   ├── transfer/
│   ├── history/
│   └── storage_management/
├── core/
│   ├── domain/          # 任务、文件、状态、值对象
│   ├── protocol/        # DTO、canonical 编码、版本协商
│   ├── security/        # pin、令牌、授权与凭证端口
│   ├── network/         # API client/server、发现、背压
│   ├── transfer/        # 分块、调度、哈希、恢复
│   ├── storage/         # DB、checkpoint、空间、导出
│   └── diagnostics/
└── platform/            # Dart 端平台接口与 channel 绑定
```

每个 feature 采用 `presentation/application` 分离；业务状态由应用用例输出，不让 Widget 根据异常字符串猜状态。

## 3. Flutter 前台

### 状态管理

允许在工程初始化任务中评估并冻结具体库。无论使用何种库，都必须满足：状态可测试、异步取消清晰、ViewModel 不持有 `BuildContext`、领域错误为类型化错误、页面重建不重复发起传输。

建议 UI 状态统一为：

```text
Idle | Loading(progress?) | Data(value) | Empty | RecoverableError(action) | FatalError
```

传输页面订阅持久化任务快照和实时指标的合并流；应用重启后先从 SQLite 恢复快照，不能依赖内存 ViewModel。

### 导航

路由至少覆盖：主页、选择文件、连接方式、扫码/展示码、设备确认、接收确认、传输详情、结果、历史/继续任务、空间管理、设置/诊断。深层页面必须支持系统返回和任务仍在后台运行的明确提示。

### 性能

- 大清单使用分页/虚拟列表；不一次构建一万行。
- 进度刷新节流到适合显示的频率，网络块事件不逐个触发整页 rebuild。
- 缩略图是可选优化，不阻塞预扫描或传输；大文件不生成全量内存预览。
- 哈希、文件枚举、数据库批量写入不得运行在 UI isolate。

## 4. 应用用例接口

| 用例 | 输入 | 输出 | 主要失败 |
| --- | --- | --- | --- |
| PrepareSelection | 平台文件句柄列表 | 冻结清单候选、来源能力、进度 | 授权失效、云文件离线、源变化 |
| StartDiscovery | 连接偏好 | 候选设备流 | 权限拒绝、网络不可用 |
| PairPeer | QR/手动配对材料 | 已授权 peer/session | pin 不匹配、令牌过期 |
| OfferTransfer | 清单与方向 | offer_id | 版本不兼容、权限不足 |
| AcceptTransfer | offer、目标位置 | task_id、空间计划 | 空间不足、位置不可写 |
| RunTransfer | task_id | 任务事件流 | 网络、块损坏、磁盘失败 |
| Pause/Resume | task_id | 新任务快照 | 旧 lease、不可恢复状态 |
| VerifyAndExport | task_id | 文件级结果 | 整体哈希失败、导出失败 |
| Cleanup | task_id、策略 | 释放空间结果 | 任务仍活动、删除失败 |

用例必须幂等或显式拒绝重复调用；例如重复 Accept 使用 `request_id` 返回同一任务，而不是创建两个暂存副本。

## 5. 本地 API 服务

协议的具体路径和字段以 `docs/protocol/v1.0-draft1.md` 为准。服务层按职责分组：

- `/v1/capabilities`：版本与能力协商。
- `/v1/pairing/*`：一次性配对和授权。
- `/v1/offers/*`：传输报价、清单分页和用户决定。
- `/v1/tasks/*`：任务状态、暂停、恢复、取消和完成查询。
- `/v1/files/{fileId}/chunks/{index}`：有边界验证的块读写。
- `/v1/diagnostics/ping`：不泄露敏感信息的可用性检查。

具体路径若与协议草案不同，以协议为准并在实现前统一修订，不能并行产生两套 API。

### 请求管线

`TLS → pin/会话身份 → 协议版本 → token/任务授权 → request_id 幂等 → 参数/范围验证 → 用例 → 结构化错误`

任何环节失败都不执行后续文件操作。错误响应包含稳定错误码、是否可重试和用户安全文案键；开发诊断只进入本地日志。

### 生命周期

本地 server 只绑定选定的局域网接口，端口可随机但必须进入已认证配对材料。无活动会话时停止监听；应用进入后台时遵守平台限制并将任务置为可恢复状态，不声称永久后台运行。

## 6. 网络与发现

- mDNS/Bonjour 发现只提供候选地址、能力提示和短期实例 ID，不建立信任。
- QR 是身份与连接参数的可信带外输入；Windows 无摄像头时由电脑展示、手机扫描。
- 手动备用入口必须携带完整地址和认证材料，不能用可猜短码代替身份验证。
- Android 热点模式下，网络适配器显式提供绑定的 socket/server 能力；不得假设系统默认路由指向热点。
- 重连进行指数退避并设上限；用户主动恢复优先，后台无限重试禁止。

## 7. 传输引擎

### 发送端

发送前对源文件建立冻结描述：稳定句柄、大小、mtime/版本信息（如可用）、块映射和摘要。每次读取前后检查可验证的源属性；变化时停止该文件并要求重新准备。

发送端维护有限 in-flight 块，响应接收端需要集合。块响应包含任务、文件、索引、偏移、长度和摘要绑定；读取错误不会返回空数据冒充成功。

### 接收端

接收端是 checkpoint 权威：

1. 验证授权、世代、索引、范围和声明长度。
2. 流式写入指定暂存位置。
3. 计算并比较块 SHA-256。
4. 对数据执行平台认可的 durable sync。
5. 在 SQLite 事务中把块标记 committed 并递增 checkpoint。
6. 事务成功后向发送方确认。

任一步失败均不得确认该块。批量 checkpoint 可优化，但崩溃后最多重传，不能漏传或假完成。
断点恢复的裁决依据始终是接收端 SQLite 已持久化的 committed 块与 checkpoint；发送端进度记录只是镜像，
不得覆盖接收端事实。

### Manifest staging

生产版本把分页清单、首次内容时间和 seal 结果写入 SQLite。首版演示可使用有界内存 registry，
但只能声明“进程内演示可用”，不能声明服务端重启恢复。30 分钟超时只清理未 seal staging；
seal 后不再过期。registry 在 seal、取消、终态失败后释放，并必须配置并发任务及内存/记录上限。

### 完成与导出

全部 committed 后重新计算整文件摘要。摘要一致才允许导出。导出使用安全文件名策略、冲突策略和尽可能原子的目标提交；导出成功记录持久化后再清理暂存。若清理失败只影响空间回收，不把已导出文件改为失败。

## 8. 空间服务

空间计划输出每个卷的解释性明细：未分配暂存、导出峰值、源暂存、数据库估算和安全余量。不能只返回布尔值。

检查时点：接收确认前、每个大文件开始前、恢复后、导出前。无法查询 provider 空间时返回 `unknown`，UI 必须让用户确认风险，不能显示“检查通过”。运行中 ENOSPC 保留 committed 状态并提供清理/更换位置/重试。

## 9. 平台端口

| 端口 | 关键操作 | 平台注意 |
| --- | --- | --- |
| FileSource | open/read/seek/reopen/capabilities | SAF、security-scoped URL、Windows handle |
| FileSink | allocate/write/sync/export/delete-temp | 实际卷、稀疏文件、原子提交 |
| NetworkBinding | enumerate/bind/listen/connect | Android 指定 Network、网卡变化 |
| Hotspot | start/stop/status/instructions | 系统确认、能力差异 |
| Discovery | publish/browse/resolve | Local Network 权限、Bonjour service |
| SecureStore | create/read/delete key material | 不回传可日志化明文 |
| Lifecycle | foreground/background/power events | 状态持久化与可恢复暂停 |
| Permissions | request/status/settings | 可解释且按需请求 |

端口结果使用能力枚举和类型化错误，例如 `seekable/reopenable/local/needsStaging/offlineUnavailable`，不通过平台名称硬编码业务分支。

## 10. 数据库与迁移

- 所有 schema 变化带单调递增版本和升级测试。
- 启动先做兼容检查；更高版本 schema 拒绝写入。
- 迁移前确保一致性备份或使用 SQLite backup API；失败回滚并保留旧数据。
- repository 对外暴露事务级方法，如 `commitChunkAfterSync`、`acquireResumeLease`，避免调用者错误排序多条 SQL。
- 历史和诊断可清理，但活动任务、恢复凭证和导出记录遵循独立保留策略。

## 11. 错误模型

错误至少包含：稳定 code、scope（task/file/chunk/platform）、retryability、safe user message key、diagnostic context 和 cause。禁止把原生异常原文直接展示给用户或作为协议错误码。

错误类别：发现/网络、配对/认证、协议/版本、源文件、目标存储、完整性、生命周期、取消、内部错误。身份或清单级异常暂停整个任务；单个文件读取/导出失败允许其他文件继续。

## 12. 依赖选择门槛

新增包前记录：用途、替代方案、维护状态、许可证、支持平台、是否接触文件/网络/密钥、二进制体积、已知安全问题和 S0 结果。关键包先做最小探针，不在完整功能 PR 中顺便引入未经验证的底层依赖。
