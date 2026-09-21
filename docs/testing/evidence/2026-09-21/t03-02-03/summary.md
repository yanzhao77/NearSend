# 运行汇总 t03-02-03：HTTPS 传输层、§8 帧定界与第一个"过网"的端点

任务：[T03-02](../../../../tasks/T03-02.md)　日期：2026-09-21　
范围：**传输层**。本运行让 `POST /transfers` 第一次真的通过 TLS 网络被调用；
仍不含 UI、不含真实文件字节传输、不含 `PUT /manifest` 之外的其余端点。

## 1. 交付

- `lib/core/network/https_control_server.dart`：TLS 终止 + §8 帧定界 + 接到既有
  `ControlPipeline`。TLS 1.3 下限设在 **context** 上，因此协商不到 1.3 的连接在握手阶段
  就被拒，而不是等到有 HTTP 请求之后。
- `lib/core/network/https_control_client.dart`：按 pin 连接的客户端，承载 ADR-0005 §1b 的
  「客户端形态」。**不跟随重定向**（§2），**关闭透明解压**（§8 不允许压缩）。
- `tooling/spikes/http_framing/main.dart`：用裸 socket 测出 dart:io 在处理器看到之前
  规范化掉了什么。原始输出：[http-framing-probe.log](http-framing-probe.log)。
- `test/core/network/https_control_transport_test.dart`：8 项，全部经真实 TLS 连接。

## 2. 实测：dart:io 替我们挡了什么、又把什么留给了我们

§8 的规则是关于**帧定界**的，而 `dart:io` 自己解析 HTTP，所以必须先知道哪些形态在
我们的代码运行之前就已经被处理。裸 socket 实测结果：

| 对端发送 | 处理器看到 |
| --- | --- |
| 两个 `Content-Length` | **引擎直接拒绝**，处理器从不运行 |
| 同一头部的两种拼写 | **引擎直接拒绝** |
| `Transfer-Encoding: chunked` | **被接受并解帧**；头部仍然可见 |
| `Content-Length` + `Transfer-Encoding` 同时 | 引擎按 chunked 定界，并**把 `Content-Length` 从 map 中移除** |
| `Content-Encoding: gzip` | 头部可见，body **未被解压** |
| `Content-Length: 005` | 被规范化为 `5` |

第四行值得单独说明：**想靠"两个都看见"来拒绝"两者同时出现"的实现做不到**——代码运行时
其中一个已经不见了。它仍然被拒绝，因为「拒绝任何 `Transfer-Encoding`」这一条覆盖了它。
所以 §8 那条规则是成立的，但**成立的理由与字面写法不同**，这一点写进了服务端的文档注释
与 `assertSupportedFraming` 的说明，以免后来者以为那是冗余检查。

## 3. 测试结果（8/8 通过，全部经真实 TLS）

| 用例 | 断言 |
| --- | --- |
| 正确 pin 创建传输 | `201`、`state=STAGING`、`cache-control: no-store`，且**数据库里确有 1 行任务** |
| 无处理器的路由 | `404` 而非 `500` |
| 畸形 target | 被 answered 为 §7 错误（400/401），且没有创建任何任务 |
| **错误 pin** | 抛 `PAIR_REJECTED`，`sawAnyCertificate=true`，且**任务数为 0**（一个请求都没到服务端） |
| 正确 pin 的对照组 | `201`，任务数为 1 |
| `Transfer-Encoding: chunked` | `400 INVALID_FIELD`，任务数为 0 |
| `Content-Encoding: gzip` | `400 INVALID_FIELD` |
| 单一 `Content-Length` 的正常请求 | 被管线处理（无凭证故 `401`） |

第一条是本任务一直缺的那块拼图：**端点不再只是"敢回答"，而是真的通过 TLS 收到了请求、
写了数据库、并把响应发了回去**。

## 4. 期间发现并修正的真实缺陷（客户端违反 §8）

接入之初 `POST /transfers` 经网络调用返回 **`400 INVALID_FIELD`**，而同一端点在
不经网络的单测里是绿的。原因不在服务端：

`HttpsControlClient` 用 `add(body)` 写请求体却**没有设置 `contentLength`**，
而 `dart:io` 在内容长度未知时会**回落到 chunked 编码**——正是一个 §8 明令拒绝的帧形态。
**服务端的拒绝是对的，错的是客户端。** 修法是显式声明长度（空 body 也声明，以免任何请求
带上 chunked 帧）。

这处缺陷的价值在于它是**帧定界规则真的起作用**的实证：如果没有那条规则，这个客户端会以
一个本协议不支持的形态长期工作下去，直到遇到一个更严格的实现才失败，而那时现场看到的是
"对方不收我的请求"，很难定位到编码方式。

## 5. 未执行 / 残留

- **仍未传输任何文件字节**：chunk 端点（`PUT .../chunks/{index}`）未实现，背压未做。
- **其余 16 个端点仍未实现**：`pair`、`decision`、`authorization`、`resume`、`status`、
  `checkpoint`、`complete`、`cancel` 等。
- **身份仍未持久化**：服务端每次启动都会生成新身份，因此 pin 每次都变。
  真机端到端之前必须补上，否则每次都要重新配对。
- **未在真机运行**：全部握手在本机 loopback 完成。**Android 侧尚未参与。**
- 未做：Windows 防火墙的正式配置、二维码展示、空间预检、导出、两端 UI。
- 本运行**不得**被读作「传输已可用」。
