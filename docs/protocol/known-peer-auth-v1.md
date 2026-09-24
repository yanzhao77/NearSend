# 已知设备实时认证 v1

状态：已实现，首次短码配对不在本协议范围内

日期：2026-09-24

## 目的与边界

本协议用于两个已经由用户授权并保存长期 P-256 公钥的 NearSend 安装重新相遇时，证明当前控制
通道的对端仍持有该长期私钥，并把当前 TLS leaf 指纹和“就绪”声明绑定到一次新鲜挑战。

它不是 PAKE，不建立首次信任，也不把 BLE 广告、设备名、IP 地址或 mDNS 记录升级为可信身份。
双方必须各自作为 verifier 发起一次挑战，分别验证对端；单向成功不能替代双向确认。

## 消息

消息使用严格 JSON：缺少字段、额外字段、错误类型、非规范 base64url、超限长度或未知版本均拒绝。

`PeerChallenge` 包含：

- `version`：固定为 `1`。
- `transactionId`：规范 UUID v4。
- `verifierDeviceId`：verifier 长期公钥 SPKI DER 的 SHA-256 小写十六进制。
- `proverDeviceId`：预期 prover 的同类 device ID。
- `challenge`：32 字节 CSPRNG 随机数，base64url 无填充。
- `protocolMajor` / `protocolMinor`：本次应用协议版本。

`PeerProof` 包含：

- `version`：固定为 `1`。
- `transactionId`：对应挑战事务。
- `publicKey`：prover 的规范 P-256 SPKI DER，base64url 无填充，最大 256 字节。
- `tlsFingerprint`：当前 TLS leaf DER 的 SHA-256 小写十六进制。
- `ready`：当前是否接受连接。
- `signature`：64 字节固定宽度 `r || s` ECDSA P-256/SHA-256 签名，要求 low-S。

挑战编码最大 1024 字节，证明编码最大 2048 字节。verifier 同时最多保存 16 个待验证挑战。

## 签名 transcript

以下字段按顺序写入 `CanonicalWriter`，整数为无符号大端：

```text
ASCII "NSPEER1"
u8 0
u16 protocolMajor
u16 protocolMinor
16 bytes transaction UUID
32 bytes verifier device ID digest
32 bytes prover device ID digest
32 bytes challenge
u8 ready (0 or 1)
32 bytes TLS leaf fingerprint digest
```

角色、版本、事务、双方身份、随机挑战、就绪状态和 TLS pin 都在签名内。交换角色、替换身份、修改
就绪状态或 TLS pin 都必须导致签名失败。

## 状态与失败关闭

- 挑战自签发起 30 秒有效，以 verifier 本地时钟判断。
- verifier 在检查证明前立即消费挑战；成功、格式错误、签名错误、撤销和过期均不可重试该挑战。
- 只有数据库中 `authorized` 且保存公钥与证明逐字节相同的 peer 才能成功。
- 成功后可更新该长期身份绑定的 TLS pin 和 `last_verified_at`。长期身份变化不能借此更新，必须重新配对。
- `ready=false` 可以证明身份出现，但不得形成可点亮绿色状态的 `VerifiedPeerSession`。
- 就绪会话 30 秒后失效；广告或地址刷新不能延长它。
- 撤销记录保留。挑战签发后再撤销时，验证仍失败关闭。

## 首次信任的未完成项

V12-07 计划要求首次雷达短码采用成熟且带密钥确认的 PAKE。当前审查的 `spake2plus 1.0.2` 仅支持
Linux/macOS 且依赖外部 OpenSSL 3；`dsrp 0.5.5` 为未审计的 0.x 纯 Dart SRP-6a，发布包没有测试
目录并要求生产方自行提供 safe prime。两者都不满足 Android/Windows/iOS 跨平台和可信向量门槛。

因此首次短码配对仍受阻，禁止以短码哈希比对、明文传输或自制加密替代。现有高熵二维码一次性
令牌与 TLS pin 路径继续作为首次配对入口。
