# S0 探针（Dart 侧）

本目录存放**探索性** Dart 探针。它们不是产品代码，也不是测试；结论经核实后应记入
`docs/decisions/` 的 ADR，并把稳定下来的机制改写成 `test/` 下的正式测试。

| 探针 | 目的 | 结论去向 |
| --- | --- | --- |
| `tls_engine/` | TLS 1.3 下限是否真实强制；pin 比对应该放在哪一层 | [ADR-0005](../../docs/decisions/ADR-0005-TLS引擎与证书供给.md)、[运行汇总](../../docs/testing/evidence/2026-09-21/t03-02-01/summary.md) |

## `tls_engine`

**这是一段一次性 spike，不要把它当作产品实现，也不要引用其中的任何常量。**

它需要一对 PEM 证书与私钥，**故意不把证书放进仓库**（`AGENTS.md` §5 禁止私钥入库）。
生成一次性证书（需要 openssl）：

```bash
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout key.pem -out cert.pem -days 30 -nodes -config openssl.cnf -sha256
```

其中 `openssl.cnf` 至少要让证书带上 `subjectAltName=IP:127.0.0.1` ——
**否则主机名校验必然失败，会把「信任库是否生效」这个被测变量掩盖掉**
（本探针第一版就踩了这个坑，场景 C 因此得出了错误结论）。

运行：

```bash
dart run tooling/spikes/tls_engine/main.dart <证书目录>
```

三个场景的含义见 [运行汇总](../../docs/testing/evidence/2026-09-21/t03-02-01/summary.md) §4。
其中**场景 C 是本探针存在的理由**：它证明「只在 `badCertificateCallback` 里比对 pin」
的写法对受信任证书**完全不比对 pin**。

保持服务端存活以便用**另一个实现**验证 TLS 版本下限（用自己的客户端验证自己的下限
是循环论证）：

```bash
dart run tooling/spikes/tls_engine/main.dart <证书目录> --hold=90 --port=18443
openssl s_client -connect 127.0.0.1:18443 -tls1_2   # 必须被拒绝
openssl s_client -connect 127.0.0.1:18443 -tls1_3   # 必须成功
```
