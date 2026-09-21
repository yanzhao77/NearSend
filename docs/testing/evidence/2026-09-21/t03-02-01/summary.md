# 运行汇总 t03-02-01：局域网前提实测与 TLS 引擎/pin 形态验证

任务：[T03-02](../../../../tasks/T03-02.md)　日期：2026-09-21　
范围：**S0 性质的前提验证**，不是端到端功能交付。本文件不声称任何传输能力已实现。

## 1. 为什么先做这一步

T03-02 要求的端到端链路依赖三个此前从未在真实环境验证过的前提：

1. 真机与 Windows 桌面真的在同一可互通的局域网（协议 §1、`AGENTS.md` §2 规则 1）；
2. Dart 侧能强制 TLS 1.3 下限（协议 §12 列为待验证）；
3. 「对**每一个**证书比对 pin」在 Dart 引擎里可以用结构性方式做到
   （协议 §2；台账 §5 已登记「只在不可信回调中比对」是错误形态）。

第 3 条尤其关键：如果做不到，整条配对链路的安全模型要重做，因此必须先验证再写传输层。

## 2. 环境

| 项 | 值 |
| --- | --- |
| Windows | Microsoft Windows 10 专业版 10.0.19045（WLAN 192.168.10.100/24，SSID `CMCC-pbD4`） |
| Android 真机 | `22081283C`（yunluo），Android 14（API 34），序列号 `EYMZ45R8AI9HZHIB`，wlan0 192.168.10.18/24 |
| Dart | 3.13.4 (stable) windows_x64 |
| Flutter | 3.47.5（本机 `C:\tools\flutter`） |
| openssl | 3.5.7（仅用于生成一次性 spike 证书与外部验证 TLS 版本，**不入仓库**） |
| 基线提交 | `c08b96d8eb5be93d517f954176f1070006c77a22` |

基线检查：`flutter analyze` 无问题；`flutter test` **1003/1003 通过**。

## 3. 局域网前提（实测，不是推断）

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 两端网段 | `ip -f inet addr show wlan0` / `Get-NetIPAddress` | 手机 192.168.10.18/24，Windows 192.168.10.100/24 |
| 同一 AP | `netsh wlan show interfaces` | Windows SSID `CMCC-pbD4`，与手机 `dumpsys wifi` 记录一致，BSSID 相同 |
| Windows → 手机 | `ping 192.168.10.18` | 3/3 回包（85–109 ms） |
| 手机 → Windows ICMP | `adb shell ping -c 3 192.168.10.100` | **100% 丢失** |
| 手机 → Windows TCP | Windows 上临时监听 18080，`adb shell nc -w 5 192.168.10.100 18080` | **CONNECTED**：服务端记录 `ACCEPTED connection from 192.168.10.18:43240`，读到 15 字节并回包 |

**结论与一个必须记住的教训**：AP **没有**客户端隔离，手机到 Windows 的**入站 TCP 可达**。
但手机到 Windows 的 **ICMP 被防火墙挡下**，因此**任何以 ping 判定「对端在线」的实现都是错的**
——可达性只能用 TCP 连接判定。这条已写入任务卡的接口与不变量。

## 4. TLS 引擎与 pin 形态（spike）

探针：`tooling/spikes/tls_engine/main.dart`（`dart run tooling/spikes/tls_engine/main.dart <certdir>`）。
原始输出：[tls-engine-spike.log](tls-engine-spike.log)。

同一进程内起服务端与三种客户端：

| 场景 | 客户端形态 | 结果 | 判定 |
| --- | --- | --- | --- |
| A | 空信任库 + 正确 pin | `status=200 callbackCalls=1` | **PASS**：放行来自**我们的比对**，不是来自信任库 |
| B | 空信任库 + 错误 pin | `HandshakeException callbackCalls=1`，且服务端总请求数未增加 | **PASS**：比对失败即关闭连接，**一个 HTTP 请求都没有发出** |
| C | 有根信任 + 该证书已加入信任库 | `status=200 callbackCalls=0` | **确认为缺陷形态**：`badCertificateCallback` 完全不被调用，**没有任何 pin 比对** |

场景 C 是本批次最重要的发现：**「只在不可信证书回调中比对 pin」的写法，会对一个
CA 签发（或已被信任）的证书完全不比对 pin**。这从实测上证实了协议 §2 那句话的必要性，
也说明该约束必须是结构性的——客户端恒用 `SecurityContext(withTrustedRoots: false)`
且永不对端证书加入信任库，使回调**必然**触发。已记入
[ADR-0005](../../../../decisions/ADR-0005-TLS引擎与证书供给.md)。

指纹的三种写法在同一份证书上的实测值（台账 §5 登记的风险的具体形状）：

```
SHA-256(叶证书 DER)  = 61f32d95798f2c3b63518e84771ec894f470d026d05713911d541e5e8da105ea   <- pin
SHA-256(PEM 文本文件) = 5cdaf16fce542d256ca18c4e414090c251d6888b55a1d25449350b5f8a05a1a8   <- 不是 pin
```

## 5. TLS 版本下限的外部验证

用**我们自己的客户端**验证**我们自己的**下限是循环论证，故改用 `openssl s_client`
（另一个实现）探测。原始输出：[tls-version-probe.log](tls-version-probe.log)。

- `openssl s_client -tls1_2` → 被服务端中止：`error:0A000126:SSL routines::unexpected eof while reading`
- `openssl s_client -tls1_3` → `CONNECTION ESTABLISHED`、`Protocol version: TLSv1.3`、
  `Ciphersuite: TLS_CHACHA20_POLY1305_SHA256`

即 `SecurityContext.minimumTlsProtocolVersion = tls1_3` 在 Windows 上是**真实强制**的，
不是「设了但没生效」。

## 6. 结论

- 三个前提**均成立**，T03-02 可以按原设计继续，不需要改架构。
- 传输层实现的硬约束已固定：TLS 1.3 下限 + 空信任库 + 恒不信任对端证书 + 我们自己比对 pin。
- **可达性判定必须用 TCP，不能用 ICMP**。

## 7. 残余与未做

- 本运行**没有实现任何端到端功能**：没有 HTTP/1.1 服务器、没有 `/v1` 端点接线、
  没有 UI、没有真实文件传输。本文件不得被读作「传输已可用」。
- 证书**供给**方式仍是待确认项（ADR-0005 §2）；本运行用 openssl 生成一次性证书，
  私钥只存在于本机临时目录，未入仓库，也**不代表**产品方案。
- 真机侧只验证了网络可达性；Android 端的 TLS 客户端（pinning 在真机上的行为）**尚未验证**。
- 未做：Android 网络绑定（B01/B02，本路径使用已有局域网故不涉及热点）、
  防火墙规则的正式配置（本次入站未被拦，但 Flutter 可执行文件首次监听时 Windows 仍可能弹窗或拦截，需在端到端阶段实测）。
- 未做三端真机、未做 iOS、未做安装包与签名。
