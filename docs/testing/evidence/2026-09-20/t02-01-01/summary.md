# T02-01 Dart canonical manifest — 运行汇总

- 运行 ID：`t02-01-01`
- 任务：[T02-01 Dart canonical manifest](../../../../tasks/T02-01.md)
- 日期：2026-09-20
- 分支：`feat/t02-01-canonical-manifest`
- 基线：`master` @ `11d4304552c4871f12cdeef11a5100de5d62eaa5`
- 主机：Windows 10 22H2，Flutter 3.47.5 / Dart 3.13.4，Python 3.10.9

## 1. 这次交付解决了什么

`docs/PROJECT_LEDGER.md` D04 记录固定向量「Python 参考生成，待 Dart/原生独立比对」。
本任务在 Dart 中实现同一套规范编码，使 `LFTM1`/`LFTC1` 不再只有单一参考实现。

**实现依据是规范而不是参考代码。** 编码器按 `docs/protocol/v1.0-draft1.md` §5.2/§5.3 的
字节布局描述编写：magic + 0 字节、定宽无符号大端整数、UUID 的 16 原始字节、
路径的 UTF-8 字节长度、以及「只有最后一块可以短」的推导规则。
`AGENTS.md` 明确警告不要逐行翻译 Python 参考实现然后把它称为跨语言验证，因此这里把向量当作
**对规范理解的外部检验**：不一致时要么是本实现误读了规范，要么是规范有歧义，两者都应在文档层面解决，
而不是去改向量。

## 2. 结果

| 检查 | 结果 |
| --- | --- |
| `dart format --output=none --set-exit-if-changed .` | 通过（无改动） |
| `flutter analyze` | `No issues found!` |
| `flutter test`（全部） | **84 / 84 通过** |
| `flutter test test/core/protocol`（本任务） | **48 / 48 通过**（日志 `protocol-tests.log`） |
| 相对链接 / 敏感信息 / CI 不变量 | 通过（158 链接、167 跟踪文件） |
| `tooling/s0` 参考探针 | 24 / 24 通过（需 Git 的 openssl 在 PATH 前，见 §6） |

### 固定向量逐字节一致

| 向量 | 覆盖 | `canonicalHex` | `manifestDigest` | `chunkManifestDigest` |
| --- | --- | --- | --- | --- |
| `empty` | 0 字节文件、0 块 | 一致 | 一致 | 一致 |
| `abc_unicode` | UTF-8 中文路径 `资料/测试.txt` | 一致 | 一致 | 一致 |
| `tail` | 4 MiB 满块 + 3 字节尾块 | 一致 | 一致 | 一致 |

这三个向量由 Python 参考实现在 Linux 上生成，未做任何修改；Dart 实现独立复算得到相同结果。

## 3. 覆盖的边界与反例

**数据形态**（`QUALITY_AND_ACCEPTANCE.md` §3）

- 空文件：0 块，`fileSha256` 为 `SHA-256("")`，`LFTC1` 摘要为「前缀 + 0 计数」的摘要。
- 尾块：最后一块短于逻辑块大小，且长度由文件大小推导而非对端声明。
- 超过 4 GiB：20 GiB 规模下块数为 5120、`count × chunkSize == size`，
  最后一块在整除时是满块、在有余数时等于余数；高索引的偏移**大于 0xFFFFFFFF**，说明使用 64 位运算。
- 越界索引被拒绝而不是回绕。
- Unicode：中文路径的 17 字节与向量的 `pathByteLength` 一致；
  非 BMP 字符（代理对）被接受，孤立代理项被拒绝。

**摘要语义**

- 对清单 JSON 求摘要会得到不同值 —— 显式断言 `manifestDigest` 不等于 `SHA-256(JSON)`，
  证明实现没有走「哈希 JSON 文本」这条被 §5.2 禁止的捷径。
- 键序与空白：把清单重新排序并重新序列化后解析，摘要不变。
- 数组顺序：仅交换 `files` 顺序，摘要变化。
- 往返：`toJson()` → `jsonDecode` → `fromJson()` 后摘要与规范字节不变。

**拒绝路径**（带稳定错误码）

| 类别 | 例子 |
| --- | --- |
| 十进制 | `00`、`01`、`+1`、`-1`、`1e3`、` 1`、`1.0`、`0x10`、空串、19 位以上、非字符串（含 JSON 数字） |
| 路径 | 绝对路径、`..`、`.`、空段、`a//b`、结尾分隔符、反斜杠、冒号、控制字符、`< > " \| ? *`、保留设备名（含带扩展名与目录内）、段尾空格或点、孤立代理项、超过 1024 UTF-8 字节 |
| 字段 | 未定义字段、缺失字段、不支持的协议版本、非规范 UUID、非 64 位小写十六进制摘要、非 v1.0 的 `chunkSizeBytes`、与大小不符的 `chunkCount`、重复 `fileId` |
| 数量 | 空 `files`、超过 10,000 个文件、超过 1,048,576 个块 |
| 块清单 | 缺失块、重复索引、乱序索引、长度与文件大小不符、非末块出现短块、块记录含未定义字段、块数量与文件大小不符 |
| 摘要校验 | `verifyDigest` 对不匹配的期望值抛出 `MANIFEST_MISMATCH` |

## 4. 过程中发现并修复的一个真实缺陷

首次运行时 5 个测试失败。根因是**一个**错误：路径校验把 `/` 放进了「Windows 非法字符」集合，
而协议把 `/` 定义为**唯一允许的分隔符**。因此任何带目录的路径都被拒绝，中文向量也因此失败。

这个缺陷只有真正跑固定向量才会暴露 —— 单看代码「拒绝非法字符」看起来完全正确。
修复方式是把 `/` 从字符集合中移除，交由分段检查处理；`a//b`、`a/`、`/` 等仍由空段、
结尾分隔符与绝对路径规则拒绝，测试覆盖未减弱。

## 5. 依赖记录

新增 `crypto 3.0.7`（Dart 团队维护，BSD-3-Clause，纯 Dart，不接触文件/网络/密钥），
按 `docs/architecture/APP_AND_SERVICE_DESIGN.md` §12 的九项要求记录于
[ADR-0002](../../../../decisions/ADR-0002-crypto依赖与SHA256.md)。自制 SHA-256 被明确否决
（`AGENTS.md` §5 禁止自制加密算法）；平台原生实现因三端一致性与流式增量成本被否决。

## 6. GitHub Actions 真实运行结果

| 项 | 第一次 | 第二次 |
| --- | --- | --- |
| run | [35523704674](https://github.com/yanzhao77/NearSend/actions/runs/35523704674) | [35524537530](https://github.com/yanzhao77/NearSend/actions/runs/35524537530) |
| 结论 | **failure** | **success** |
| 通过 | Format/analyze/test、Android 构建、Windows 构建 | 四个作业全部通过 |
| 失败 | Repository checks → `Markdown relative links` | — |
| 记录 | `ci-run-35523704674-FAILED.json`（保留未覆盖） | `ci-run-35524537530-SUCCESS.json` |

### 这次失败暴露的问题与修复

失败原因是一个**链接层级写错**：`t02-01-01/summary.md` 指向 ADR-0002 时只上溯了三级目录，
而正确层级是四级。

更值得注意的是为什么本地没有发现：本地确实跑过链接检查并报告「all relative links resolve」，
但检查范围是**已跟踪文件**，而当时这些新文档还没有 `git add`。
检查器其实打印了未跟踪文件的警告，但它位于结论行之上 —— 用 `Select-Object -Last 2` 看输出时，
警告被当成普通行略过了。

**这是同一类问题第二次把坏链接送进 CI**（T01-02 首次运行是第一次）。因此这次不只是修链接，
而是改变了检查行为：

- `check_links.py` 增加 `--strict`：存在未跟踪 Markdown 时**直接失败**而不是只警告；
- `check.ps1`（本地「一次跑完全部门禁」的入口）使用 `--strict`；
- 结论行本身带上 `(tracked files only - see the warning above)`，使截断日志也无法掩盖它。

把文件暂存是一行操作，而不覆盖工作区的「通过」是误导性的。

## 7. 已知缺口与限制

1. **NFC 未强制。** 协议 §5.1 要求接收端拒绝非 NFC 路径；检测需要 Unicode 规范化数据，
   Dart SDK 不提供，选择实现属于依赖决策。本任务**未实现**该拒绝，
   并以 `RelativePathRules.enforcesNfcNormalisation = false` 与一条断言把缺口显式暴露，
   同时在台账 §5 登记为待人工决策项。**该缺口必须在协议冻结前解决。**
   注意这不是 T02-01 的退出门槛，但它是一项真实的规范符合性缺口，不作为「已完成」的一部分被掩盖。
2. **协议未冻结。** 通过固定向量只说明本实现与草案一致，不代表协议已冻结；
   冻结仍需 T02-02 的完整错误模型、版本协商与幂等规则。
3. 本任务不读取用户文件、不做流式哈希调度、不涉及网络与存储；这些属于 T03/T04。
4. 本机 `tooling/s0` 需要 Git for Windows 的 `openssl` 排在 anaconda 的 `openssl` 之前才能跑满
   24 项（anaconda 的二进制硬编码了不存在的构建路径）。这是本机环境问题，已在 T01-01 证据中记录；
   Linux CI runner 使用系统 openssl，不受影响。
5. `flutter test` 的固定向量读取依赖从包根目录运行（`docs/protocol/vectors-v1.json`）；
   从其他目录运行会给出明确的 `StateError` 提示。
