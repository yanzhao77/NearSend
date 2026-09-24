# NearSend Bootstrap 二维码 v1

状态：载荷已实现；图像生成、扫码和入网纵向流程尚未完成

日期：2026-09-24

## 分发与兼容

扫描入口先使用严格 JSON 扫描器检查 UTF-8、4096 字节上限、重复键和结构，再按顶层 `kind` 分发：

- `lft-pair`：交给既有 v1.0 严格解析器，保持旧码兼容。
- `nearsend-bootstrap`：按本文 `formatVersion: 1` 解析。
- 其他类型：拒绝，不猜测、不降级。

## 字段

顶层字段必须恰好为：

| 字段 | 约束 |
|---|---|
| `kind` | 固定 `nearsend-bootstrap` |
| `formatVersion` | 固定整数 `1` |
| `mode` | `reachableNetwork` 或 `networkBootstrap` |
| `invitationRole` | v1 固定 `host`，绑定邀请发起角色 |
| `deviceId` | 长期身份 P-256 SPKI DER 的 SHA-256 小写十六进制 |
| `identityPublicKey` | 同一长期身份的规范 SPKI DER，base64url 无填充，最多 256 字节 |
| `pairing` | 完整既有 `lft-pair` 对象，含 TLS pin、候选、会话和 32 字节一次性令牌 |
| `wifi` | `networkBootstrap` 时必需，其他模式必须为 `null` |

解析器重新从 `identityPublicKey` 计算 `deviceId`，不接受自报 ID。嵌套 `pairing` 继续执行既有 TLS pin、
UUID、候选数量/地址、协议版本和一次性令牌校验；bootstrap 邀请声明最长 120 秒，最终有效性仍以
发行方内存中的未消费会话为准，扫码方墙上时钟不产生授权。

`wifi` 字段必须恰好包含：

- `ssid`：1..32 UTF-8 字节，不含 NUL。
- `passphrase`：8..63 个可打印 ASCII 字符。
- `security`：`wpa2` 或 `wpa3`；开放热点拒绝。

只有系统热点成功建立并返回真实凭据后才能生成 `networkBootstrap`。热点密码不得写入日志、历史、
SQLite、崩溃文本或对象 `toString`。二维码过期只撤销 NearSend 邀请；若系统热点密码没有轮换，产品
不得声称旧图片已经无法加入 Wi-Fi。加入网络后仍必须验证 TLS pin、完成配对并逐次确认接收文件。
