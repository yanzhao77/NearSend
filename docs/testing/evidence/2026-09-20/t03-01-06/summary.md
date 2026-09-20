# T03-01 `/v1` 响应体契约 — 运行汇总

- 运行 ID：`t03-01-06`
- 任务：[T03-01 同网二维码配对与信任](../../../../tasks/T03-01.md)
- 日期：2026-09-20
- 分支：`feat/t03-01-api-responses`
- 基线：`master` @ `9a7a87b`
- 主机：Windows 10 22H2，Flutter 3.47.5 / Dart 3.13.4

## 1. 本次实现的内容

| 文件 | 内容 |
| --- | --- |
| `lib/core/protocol/api_responses.dart` | §7 的成功响应体：ack、状态、offers、创建、块写入结果、控制轮询、授权/恢复凭证、`nextIndex`（新增） |
| `lib/core/protocol/transfer_state.dart` | `wireName` / `fromWireName`：§10 的线上状态名 |
| `lib/core/protocol/protocol_validation.dart` | `encodeDecimalString`：与 `parseDecimalString` 配对的编码端 |
| `test/core/protocol/api_responses_test.dart` | 49 项测试 |

测试规模：Flutter **653 → 702**；协议层测试 292 → 341。

## 2. §4 决定哪些数字是字符串、哪些是 JSON 数字

§4 写得很明确，但很容易读错：

> 字节数、块编号、chunkCount、leaseEpoch、checkpointSeq：**十进制字符串**
> 协议版本、chunkSizeBytes、length、fileCount、pageLimit 使用 **JSON 整数**

所以 `committedBytes`、`leaseEpoch`、`totalBytes`、块 `index` 以**字符串**传输，
而 `length`、`fileCount` 以**数字**传输——把两者互换的响应，对端读不出来。
每个模型内部存 `int`，在边界上用 `encodeDecimalString` / `parseDecimalString` 转换，
所以「线上长什么样」是每个字段**一处**的决定，而不是调用方随手传了什么。

测试直接把这一点钉住：一个 offer 的 `fileCount` 必须是 `int`、`totalBytes` 必须是 `String`；
把 `totalBytes` 写成数字被拒、把 `fileCount` 写成字符串被拒、`totalBytes` 带前导零被拒。

顺带补上了缺失的编码端：`encodeDecimalString` 会拒绝负数与超范围值——
一个负数在 §4 下**没有合法编码**，让 `toString()` 顺手产出 `"-1"` 才是隐患。

## 3. §10 的状态名：从枚举常量推导，而不是第二张表

§7 与 §10 在线上用 UPPER_SNAKE（`WAITING_ACCEPT`、`CHECKING_RESUME`），
而 Dart 惯例让枚举常量是 camelCase。实现**从常量推导**线上名，而不是维护第二张表：
改名的常量会同时改变两者，也不存在「忘了更新表」的情况。

有一条测试把 §10 写的 16 个名字作为**数据**列出并逐一比对，同时断言反解为正确的状态。
`fromWireName` 对未定义名字返回 **null 而不是默认值**——
猜错状态正是两个实现在「任务是否仍可续传」上分叉的方式。

## 4. 凭证只出现在两种响应里

§7：「成功体中的 token 字段**只**出现在专门授权/恢复响应，所有控制响应 `Cache-Control: no-store`」。

这做成**接口**而不是一个标志位：`TokenBearingResponse` 只被 `AuthorizationGrant`
与 `ResumeGranted` 实现，另有一条测试断言其余每一种响应体**都不是**它——
所以「状态的 token 意外带上凭证」会让测试失败，而不是等人在评审里发现。

两个凭证模型的 `toString` 都刻意不渲染值（有测试断言输出不含令牌）。

**202 形态明确拒绝令牌**：§11 说用户确认不应占用一个长期请求，
在 202 里发令牌等于**在工作完成前就把凭证交出去**。

## 5. 其它被钉住的规则

| 规则 | 出处 |
| --- | --- |
| `{stored:true}` 与 `{mirrored:true}` 是两个不同类型 | §9 说服务端「只更新显示镜像」，用 `stored` 回答等于声称做了更多 |
| offers 每页 ≤128，`nextCursor` 为 null 或非空字符串 | §7（空字符串被拒：null 已经表示结束，不该有第二种说法） |
| 空 offers 页合法 | §6「未知会话不能枚举 offers」——没有 offer 是答案，不是错误 |
| 块写入状态只有 `verified_pending` / `committed` | §8 |
| 控制命令按 seq **升序**，`lastSeq` 不得小于其描述的命令 | §7「命令重复按 seq 幂等」需要序列有序 |
| 命令类型只有 `pause` / `cancel` | §7 |
| `nextIndex` 必须等于该页的 `endIndex` | §7 把它加在 §6 的页体上 |

`nextIndex` 的规则值得一提：一个不等于 `endIndex` 的 `nextIndex`
会留下**任何后续页都填不上的缺口**，所以它在解析时就被拒绝。

## 6. 实际执行的检查

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 格式化 | `dart format lib test tooling` | 通过 |
| 静态分析 | `flutter analyze` | `No issues found!` |
| 全量测试 | `flutter test` | **702 passed** |
| 协议层测试 | `flutter test test/core/protocol` | **341 passed** |
| 链接检查 | `python tooling/checks/check_links.py --strict` | 无断链 |
| 机密检查 | `python tooling/checks/check_secrets.py` | 无凭证材料 |
| CI 工作流检查 | `python tooling/checks/check_ci_workflow.py` | 不变量成立 |

## 7. 未执行与限制

1. **§9 的状态体未建模**：`{transferId,manifestDigest,state,leaseEpoch,checkpointSeq,committedBytes,fileId?,missingChunkRanges?,snapshotId?,nextCursor?}`
   连同缺块区间的校验（两端包含、递增、不重叠、不越界、每页 ≤1024）**未做**。
   它自己的形状还有一处草案留白（见 §8 第 1 条）。
2. **二进制块响应不是 JSON 体**：§8 的 `GET .../chunks/{index}` 返回二进制，
   连同它的头规则（单一 `Content-Length`、拒绝 `Transfer-Encoding`、不许压缩）完全未实现。
3. **没有端点逻辑、没有 HTTP 层**：这些模型会生成与解析，但**没有任何地方发出它们**，
   也没有鉴权决定；`Cache-Control: no-store`（§7 要求所有控制响应带它）未实现。
4. **`POST /transfers` 与 staging 生命周期**未实现；30 分钟窗口仍无执行者。
5. **`totalBytes` 归入「十进制字符串」是读法**：§4 只写「字节数」，没有逐字段点名
   （见 §8 第 2 条）。
6. 未在 Android/iOS 真机运行。

## 8. 需要人工重点复核的区域

- **§9 缺块区间的线上形状未定**：§9 说「missingChunkRanges 是两端包含的**十进制字符串对**」，
  但没写这一「对」是二元素数组还是 `{start,end}` 对象。本次**故意未实现该体**，
  以免以偏好定下留白处；实现前需确认。
- **`totalBytes` 的编码归属**：本读法按 §4 的「字节数」把它当作十进制字符串。
  若维护者认为它属于 JSON 整数一类，需要改。
- **`nextCursor` 拒绝空字符串**是本实现的读法（null 表示结束）。§7 只说「null 或 string」。
- **`AuthorizationGrant` 的两个秘密都按 32 字节 base64url 校验**：
  §3 只说访问令牌是 32 字节随机值，未逐字说明这两个字段的长度。若它们有不同长度，需改。
- **控制命令的上限未设**：§7 未规定一页命令数量的上限，本层也未设。
  实现 HTTP 层时应确认是否需要（§4 的 1 MiB 控制体上限是唯一的现存约束）。
