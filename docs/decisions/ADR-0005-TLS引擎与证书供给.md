# ADR-0005 TLS 引擎、pin 比对形态与证书供给

- 状态：**引擎、pin 形态与证书供给均已实现并测试**；`pointycastle` 依赖待维护者追认
- 日期：2026-09-21
- 任务：T03-02
- 依据：协议 §2/§3/§12、`AGENTS.md` §2 规则 8、§3（依赖不得凭偏好定案）、§5
- 证据：[TLS 引擎 spike 日志](../testing/evidence/2026-09-21/t03-02-01/tls-engine-spike.log)、
  [TLS 版本下限外部验证](../testing/evidence/2026-09-21/t03-02-01/tls-version-probe.log)

## 背景

协议 §2 要求 TLS 最低 1.3，并且「**即使证书受系统 CA 信任也必须比对 pin**，不能只在
'不可信证书回调'中比对」。这两条此前从未在真实引擎上验证过，属协议 §12 明确列为
「需要目标端验证后才能冻结」的事项。同时，服务端需要一对叶证书与私钥，而项目禁止把
私钥写进源码或仓库（`AGENTS.md` §5）。

## 已验证的事实（不是推断）

`tooling/spikes/tls_engine/main.dart` 在同一进程内起服务端与三种客户端，实测结果：

1. **TLS 1.3 下限是真实强制的。** 服务端 `SecurityContext.minimumTlsProtocolVersion = tls1_3`
   + `HttpServer.bindSecure`；用**外部实现** `openssl s_client` 验证（用我们自己的客户端验证
   自己的下限是循环论证）：`-tls1_2` 被中止（`unexpected eof while reading`），
   `-tls1_3` 成功（`Protocol version: TLSv1.3`、`TLS_CHACHA20_POLY1305_SHA256`）。
2. **`badCertificateCallback` 不会为受信任的证书调用。** 场景 C：把该证书加入信任库后，
   回调调用次数为 **0**，请求照常成功。**这直接证明**「只在不可信回调里比对 pin」的写法
   会对一个 CA 签发的证书**完全不比对 pin**。
3. **空信任库 + 自己比对，可以让每一个证书都经过我们的比较。** 场景 A：信任库为空时，
   回调必然触发（断言持有 `callbackCalls >= 1`），请求被**我们的比对**放行；场景 B：
   同一形态下 pin 不符 → `HandshakeException`，且服务端**收到的 HTTP 请求数没有增加**
   （即比对失败时一个 HTTP 请求都没有发出），满足协议「比对失败关闭连接」。
4. **pin 的三种写法确实不同。** 同一份证书：`SHA-256(DER)` = `61f32d95…`，
   `SHA-256(PEM 文件)` = `5cdaf16f…`。台账 §5 早已登记「弄错会得到一个看似合理却永远
   匹配不上的 pin」，此处的实测值是该风险的具体形状。

## 决策

### 1. 客户端的 pin 比对形态（已接受）

**先说结论**：pin 的强制点必须落在**信任库**上，`badCertificateCallback` 只能作为
fail-closed 的纵深防御，**不得**承担 pin 判定。

实现层证据（Dart SDK `runtime/bin/security_context.cc`，`SSLCertContext::CertificateCallback`）：

```c
if (preverify_ok == 1) { return 1; }   // 预验证通过就直接放行，Dart 回调根本不会被调用
```

即：**回调只对「无法被已配置信任根认证」的证书触发**。这与本批次 spike 的场景 C 实测
完全一致（把证书加入信任库后 `callbackCalls == 0`，请求照常成功）。因此任何「保留系统
根信任 + 在回调里比对 pin」的写法，都会对一个能链到受信任根的证书**完全不比对 pin**。

**采用形态**（在 `test/core/security/tls_identity_test.dart` 中以**真实握手**逐条测过）：

1. `SecurityContext(withTrustedRoots: false)` —— 不加载任何系统根。
2. 用 `setTrustedCertificatesBytes` 装入**恰好那一张**由二维码携带的 pin 所对应的对端证书。
   于是「被信任」在构造上就等于「等于 pin」，由 TLS 栈（BoringSSL）完成匹配，
   不依赖我们自己的比较是否正确实现。
3. `badCertificateCallback` **比对同一个 pin** 并据此返回 true/false，**不是**恒返回 false。
   这是实测推翻了本 ADR 初稿的一处：dart:io **即使证书已被信任库接受，也仍然校验 SAN/IP**，
   失败时抛 `IP address mismatch`。若回调恒返回 false，则当客户端用一个证书里没写的地址
   （换了网段的局域网 IP、别名、热点网关）去连对端时，**一个指纹完全正确的连接会被拒绝**。
   实测同时给出了这条规则的边界：信任库命中**且名字匹配**时回调调用次数为 **0**；
   信任库命中但**名字不匹配**时回调**会被调用**。所以第 2 步负责「不是 pin 就连不上」，
   第 3 步只负责把「名字」这一项从身份判定里移出去——两者比对的是同一个 pin，
   没有任何一条路径能放行指纹不同的证书。
4. 连接建立后，在 `peerCertificate.der` 上**再显式比对一次** `SHA-256(DER)` 与 pin。
   这一步让协议 §2「必须比对 pin」这条规则在代码里有一个可读、可测、可断言的落点。

3 与 4 不构成同一条单点：任一步被误配，另一步仍会拒绝指纹不符的对端。测试覆盖了两个方向——
「指纹不同 → 拒绝且服务端未收到任何请求」与「名字不匹配但指纹相同 → 放行」。

**实践推论**：证书仍应把客户端可能使用的地址写进 SAN（`tls_identity.dart` 的
`subjectAltNames`）。回调只是兜底，不是让证书可以不带名字的理由。

### 1b. 两种形态必须分开说，因为二维码里没有证书

上面那套「信任库装 pin 证书」的形态**只适用于已经拿到证书的一方**（自检、以及将来重连时
客户端已把证书持久化下来的情形）。**配对时客户端做不到**：§3 的二维码字段是
`kind / protocolMajor / protocolMinor / serverFingerprint / sessionId / candidates /
pairToken / expiresInSeconds`，**只有指纹，没有证书**。所以首次连接时客户端没有任何东西
可以放进信任库。

配对客户端的形态因此是另一种，见 `lib/core/network/https_control_client.dart`：

- 信任库**保持为空**（`withTrustedRoots: false`），
- `badCertificateCallback` 里比对 `SHA-256(certificate.der) == pin` 并据此返回。

这一形态之所以安全，恰恰是因为信任库是空的：**没有任何证书能通过预验证，因此回调必然对
每一个证书触发**，「受信任证书绕过回调」的危险形态在这里无从发生（spike 的场景 A/B 即此形态）。
而它之所以必要，是因为回调是唯一能拿到 DER 的地方。

两种形态的判据可以一句话概括：**手上有没有那张证书**。有，就用信任库；没有，就用回调，
但那时信任库必须为空。写成代码时不要把它们混用在同一个上下文里——
混用的结果要么是名字不匹配被拒（本文档记录过的那次失败），要么是回到「受信任即放行」。

**离线时钟与主机名**：身份由 pin 唯一确定。**有效期**完全不参与判定——证书的有效期被
刻意写成 2000-01-01 至 2049-12-31（UTC 时间能表达的最大跨度），因为离线设备的时钟不可信，
一年期的证书会让一只时钟错乱的设备**连不上自己**，而这正是 §2 说的
「不因离线时钟错误改成接受任意证书」要避免的失败。**主机名**则无法完全排除：
dart:io 会校验它（见上），故本决策的读法是「不**依赖**名字来判定身份」，
并把名字不匹配的情形交给同一个 pin 比对来兜底，而不是宣称名字不参与。
协议 §2 说「证书日期与主机名策略须在目标引擎原型中明确」，本节即为该明确化的结果。

**已知不可配置项**：Dart 的 `SecurityContext` **没有**密码套件设置接口，
`SSL_CTX_set_cipher_list(ctx, "HIGH:MEDIUM")` 在 SDK 内硬编码，且只提供
`minimumTlsProtocolVersion`（`tls1_2`/`tls1_3` 两个取值），没有上限版本 API。
故本项目的 TLS 参数可约束范围是「最低版本 + 信任库」，其余由 BoringSSL 默认决定；
这一限制必须写进协议 §12 的待冻结事项，不得声称套件已被约束。

### 2. 证书供给（待确认，本 ADR 不擅自定案）

服务端私钥只能进入平台安全存储（`AGENTS.md` §5）。已排除的做法：

- **把私钥提交进源码/仓库**：直接违反 §5，否决。
- **构建期用 openssl 生成并打包**：同上，且使每次安装共用同一身份。
- **用平台证书存储（Windows cert store / Android Keystore）并由 dart:io 引用**：
  未找到任何 Dart 包能让 `SecurityContext` 使用不可导出的平台私钥句柄；若存在请指出。
  该路径还破坏「三端共用一份实现」。

平台私钥不可导出这一条已核实到上游：`SecurityContext` 只有
`usePrivateKey(file)` / `usePrivateKeyBytes(List<int>)`（PEM 或 PKCS#12/PKCS#1 字节），
**没有** key-provider 签名器 / PKCS#11 / CNG 接口；上游
[dart-lang/sdk#42904](https://github.com/dart-lang/sdk/issues/42904)（2020 年提出）
verbatim 写着「It isn't possible to use the Android Keystore (or the iOS KeyChain) to
provide the private key without exposing it」，至今 **仍开放**。Windows 侧
`security_context_win.cc` 只用 crypt32 枚举**证书**作为信任根，从不获取私钥句柄。

因此首版采用**首次运行时在 Dart 内生成自签叶证书与密钥，私钥字节交给平台安全存储**。
候选核实结果（2026-09-21 取自 pub.dev API + 仓库 LICENSE）：

| 候选 | 版本/日期 | 许可证 | 依赖面 | 维护状态 | 结论 |
| --- | --- | --- | --- | --- | --- |
| `pointycastle`（+ `asn1lib`，本地组装 TBSCertificate） | 4.0.0 / 2025-02-19 | **MIT**（[LICENSE](https://github.com/bcgit/pc-dart/blob/master/LICENSE)） | 仅 `collection`、`convert` | 慢但存活：仓库最后推送 2025-03-08，66 个未关 issue，bcgit 组织 | **倾向采用** |
| `asn1lib` | 1.6.5 / 2025-06-24 | GitHub 判定 **BSD-2-Clause**；其 LICENSE 头部却指向 BSD-3-Clause URL、正文只有 2 条款 → **SPDX 存歧义** | 无 | 小、静、0 未关 issue | 需许可证澄清后再引入 |
| `basic_utils` | 5.8.2 / 2025-02-23 | MIT | 连带 `http`、`archive`、`pointycastle`、`logging`、`json_annotation` | **休眠**：19 个月无提交、单一维护者、pub.dev 发布者为 **unverified uploader** | **不采用** |
| `cryptography` | 未核对 | 未核对 | 未核对 | 未核对 | 未评估 |

**不采用 `basic_utils` 的理由（三条，均已核实）**：

1. 它会把 **HTTP 客户端库**拖进一个卖点就是「不联网」的应用，平白扩大审计面；
2. 其 `PKCS12Utils.generatePkcs12` 的默认参数是**坏的**：`certPbe` 默认
   `PBE-SHA1-RC2-40`（40 位 RC2，已破）、`digestAlgorithm` 默认 `SHA-1`。
   iOS 的 `usePrivateKey` **只接受 PKCS#12**，所以这条默认值有实际触达路径；
3. `X509Utils.generateSelfSignedCertificate` 的 `serialNumber` 默认 `'1'`，
   `CryptoUtils.ecSign` 默认 `'SHA-1/ECDSA'` —— 都是「默认值不安全」的形状。

**采用 `pointycastle` 的代价必须写清楚**：纯 Dart 实现**不提供常数时间保证**，
私钥始终存在于 Dart 堆内存中（无硬件隔离），且**未做 CVE 检索**（本次调研未覆盖，
引入前必须补）。X.509 的 DER 组装需自行编写——但这是**编码**而非密码学，
且可以用 openssl 独立解析来验证。

验证方法（无论最终选哪个候选都必须做）：

1. 生成证书后用 **openssl 独立解析**，确认 `SHA-256(DER)` 与 Dart 侧计算值一致；
2. 在 Android 侧确认 `X509Certificate.der` 得到**同一摘要**（三端摘要必须一致）；
3. 用 `Random.secure()` 播种 pointycastle 的 `FortunaRandom`，并断言两次生成的密钥不同、
   序列号是随机值而非常量。

## 影响

- 传输层实现（`HttpServer` + 空信任库客户端）以此为约束；任何「有根信任 + 回调」的写法
  都是安全缺陷，应当在评审中按缺陷处理。
- 证书生成依赖落地时必须补一份依赖 ADR（许可证、维护状态、安全影响），并保持
  `pubspec.lock` 同步。
- 本 ADR 的 §1 可立即执行；§2 在维护者确认前不得在台账写成已冻结。
