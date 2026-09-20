# ADR-0002 引入 `crypto` 作为 SHA-256 实现

- 状态：已接受
- 日期：2026-09-20
- 任务：T02-01
- 依据：`AGENTS.md` §3/§5、`docs/architecture/APP_AND_SERVICE_DESIGN.md` §12、`docs/protocol/v1.0-draft1.md` §5.2/§5.3

## 背景

协议 v1.0 的清单摘要（`LFTM1`）与块清单摘要（`LFTC1`）都以 SHA-256 为最终摘要算法，
分块校验与整文件终检同样使用 SHA-256。Dart SDK 的 `dart:core`/`dart:io` 不提供任何哈希实现，
因此必须引入一个 SHA-256 实现。

`ADR-0001` 记录的是「T01-01 不引入任何第三方运行时依赖」，那条决定只针对 T01-01 的范围；
本次是协议实现第一次真正需要密码学原语，按 §12 单独评估并记录。

## 决策

引入 `crypto`（`pubspec.yaml`：`crypto: ^3.0.7`，解析结果 `crypto 3.0.7`，附带传递依赖 `typed_data 1.4.0`）。

## §12 要求的评估项

| 项目 | 内容 |
| --- | --- |
| 用途 | SHA-256 摘要：`LFTM1`、`LFTC1`、分块校验、整文件终检；后续流式哈希 |
| 替代方案 | ① 自己实现 SHA-256 —— 自制密码学实现违反 `AGENTS.md` §5「禁止自制加密算法」，否决；② 通过平台通道调用 Android `MessageDigest`／Windows `BCrypt`／iOS `CryptoKit` —— 每个平台一套实现，三端一致性风险高，且哈希必须能在大文件流中增量计算，跨平台通道会带来额外复制，否决；③ `package:cryptography`（第三方、维护者非 Dart 团队）—— 功能远超所需且引入更大的依赖面，否决；④ 使用 `pointycastle` —— 体积更大，同样超出所需 |
| 维护状态 | Dart 团队（dart.dev）官方维护，属于 dart-lang 组织的核心包之一 |
| 许可证 | BSD-3-Clause（与 Flutter/Dart 生态一致） |
| 支持平台 | 纯 Dart 实现，Android／Windows／iOS 均支持；无原生代码，不涉及平台插件注册 |
| 是否接触文件、网络或密钥 | **否**。只做内存中的字节到摘要变换；不读取文件、不访问网络、不生成或持有任何密钥 |
| 二进制体积 | 纯 Dart，主要成本是被 tree-shaking 后保留的 SHA-256 实现，可忽略 |
| 已知安全问题 | 无未修复的已知问题（`crypto` 3.x 为当前主版本） |
| S0 结果 | 本任务内以协议固定向量验证：`docs/protocol/vectors-v1.json` 的三个向量由 Python 参考实现生成，Dart 实现独立复算得到**完全相同的字节序列与摘要**，见 `docs/testing/evidence/2026-09-20/t02-01-01/` |

## 影响

- `pubspec.lock` 已同步更新，CI 的「依赖锁文件已跟踪且非空」检查覆盖本次变更。
- 后续流式哈希（大文件分块）应使用 `crypto` 的增量接口，避免把整个文件读入内存 ——
  这是 `AGENTS.md` §2 的硬性要求，也是选择纯 Dart 实现的原因之一。
- 若将来需要 AEAD 或密钥派生（例如凭证加密），**不得**因此自动扩大 `crypto` 的使用范围：
  那属于新的安全决策，需要单独的 ADR 与 S0 验证。

## 未决

- 协议 §5.1 要求接收端拒绝非 NFC 规范的路径。检测非 NFC 需要 Unicode 规范化实现，
  Dart SDK 不提供，`crypto` 也不涉及。该缺口已在
  `docs/PROJECT_LEDGER.md` §5 登记，候选方案（引入规范化包／平台原生 API／
  由发送端负责并对摘要做附加绑定）需由维护者决定后再实现，本 ADR 不预设结论。
