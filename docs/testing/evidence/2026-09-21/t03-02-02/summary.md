# 运行汇总 t03-02-02：TLS 身份（自签证书生成）与 pin 形态定案

任务：[T03-02](../../../../tasks/T03-02.md)　日期：2026-09-21　
决策：[ADR-0005](../../../../decisions/ADR-0005-TLS引擎与证书供给.md)　
范围：**TLS 身份层**。本运行不含 HTTP 服务器、端点接线、UI 或任何真实文件传输。

## 1. 交付

- `lib/core/security/tls_identity.dart`：首次运行时在 Dart 内生成 P-256 自签叶证书与密钥。
  私钥**只以字节返回**，模块没有任何写文件的路径；调用方负责交给平台安全存储。
  pin 复用既有权威实现 `serverFingerprintOf`，不新增第二处指纹定义。
- `test/core/security/tls_identity_test.dart`：9 项，含 4 项真实 TLS 握手。
- `tooling/spikes/tls_identity/dump.dart`：把生成的 PEM 落到**仓库外**的临时目录，
  供外部实现校验；脚本自身拒绝写入仓库内（`AGENTS.md` §5 禁止私钥入库）。
- 新依赖 `pointycastle` 4.0.0（ADR-0005 §2 已记录许可证、维护状态与代价）。

## 2. 独立验证（openssl 3.5.7，未参与生成）

原始日志：[tls-identity-openssl-verify.log](tls-identity-openssl-verify.log)。

| 检查 | 结果 |
| --- | --- |
| openssl 能解析该证书 | ✅ `subject=CN=NearSend`、`issuer=CN=NearSend` |
| 有效期 | ✅ `notBefore=2000-01-01`、`notAfter=2049-12-31` |
| 序列号 | ✅ 随机（`786286925626FC81`），非常量 |
| keyUsage | ✅ critical，`Digital Signature` |
| extendedKeyUsage | ✅ `TLS Web Server Authentication` |
| basicConstraints | ✅ critical，`CA:FALSE` |
| subjectAltName | ✅ `IP Address:127.0.0.1, IP Address:192.168.10.100` |
| **openssl 的 `SHA-256(DER)` == Dart 的 pin** | ✅ `f21f46bf…9c98`，`MATCH: True` |
| openssl 能解析私钥 | ✅ `Private-Key: (256 bit)` |
| **私钥与证书是否同一对** | ✅ `public keys identical: True` |

第 8 行是 ADR-0005 明确要求的那条验证：**必须由没有生成它的实现确认指纹一致**，
否则一个自制的编码错误会产出一个「自洽但只有我们自己认得」的证书。

## 3. 本批次推翻了一处先前结论（重要）

ADR-0005 初稿写的是「信任库只装 pin 证书 + `badCertificateCallback` **恒返回 false**」。
按该形态写成的测试**失败**了：

```
HandshakeException: CERTIFICATE_VERIFY_FAILED: IP address mismatch
```

即 **dart:io 即使证书已被信任库接受，仍然会校验 SAN/IP**。若回调恒 false，
则当客户端用一个证书里没写的地址去连对端时，**一个指纹完全正确的连接会被拒绝**。

实测同时给出了这条规则的边界，两个方向都有测试固定：

| 情形 | 信任库 | 名字 | 回调调用次数 | 结果 |
| --- | --- | --- | --- | --- |
| A | 只装 pin 证书 | 匹配 | **0** | 放行（安全判定来自信任库） |
| B | 只装别的证书 | 匹配 | >0 | 拒绝，**服务端未收到任何请求** |
| C | 只装 pin 证书 | **不匹配** | **>0** | 回调比对 pin 后放行 |
| D | 只装别的证书 | 不匹配 | >0 | 拒绝（回调比对的是别人的 pin） |

结论：pin 的形态是**两个机制比对同一个 pin**——信任库保证「不是 pin 就连不上」，
回调只负责把「名字」这一项从身份判定里移出去。没有任何一条路径能放行指纹不同的证书。
ADR-0005 §1 已按此更新，并写明「回调只是兜底，不是让证书可以不带 SAN 的理由」。

**这处错误的保留价值**：如果只写文档不写握手测试，这个形态会被当成已验证而进入传输层，
到真机上才以「换个网段就连不上」的形式暴露，且现场很难定位到 SAN。

## 4. 未执行 / 残留

- **未在 Android 真机上验证**：本运行的握手全在 Windows 上完成。Android 侧
  `X509Certificate.der` 是否给出同一摘要、`badCertificateCallback` 在 Android 上的调用时机
  是否与 Windows 一致，**仍需真机证据**（这是 T03-02 剩余验收项之一）。
- **未验证硬件隔离**：私钥存在于 Dart 堆内存中，纯 Dart 实现不提供常数时间保证、
  也无平台密钥库保护。ADR-0005 已记录该代价；若将来要求不可导出的硬件密钥，
  必须改为原生实现端点。
- **未做 CVE 检索**：`pointycastle` 的 CVE 状态在依赖调研中标记为未确认，
  引入生产前应补。
- 未做：HTTP 服务器、`/v1` 端点接线、UI、真实文件传输、证书在平台安全存储中的持久化
  （目前每次调用都会生成一份新身份；**持久化与「同一安装一个身份」是下一步**）。
- 本运行**不得**被读作「配对已可用」或「传输已可用」。
