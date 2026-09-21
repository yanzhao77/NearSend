# ADR-0004 staging 持久化、生命周期与恢复权威

- 状态：已接受；SQLite staging 实现待完成
- 日期：2026-09-21
- 任务：T03-01、T04-01
- 依据：协议 §6/§8/§9、`AGENTS.md` §2 规则 5–7

## 背景

当前 `ManifestStagingRegistry` 把清单页保存在进程内。它足以演示分页、重传和 seal，
但进程重启会丢失未 seal 及已 seal 的清单，不能支撑“服务端重启后继续”的产品承诺。
同时，协议线上状态用 `UPPER_SNAKE_CASE`，SQLite 已有数据使用 lower/camel-case；
若业务代码直接拼写两套字符串，很容易把线上值写入数据库。

## 决策

1. **生产版本的 manifest staging 必须进入 SQLite。** 第一版演示允许使用有界的进程内
   registry，但必须明确标注“不支持服务端重启恢复”，不得把幂等重传说成重启恢复已经实现。
2. **30 分钟超时只作用于未 seal 的 staging。** 时间从首次收到内容起算；seal 后不再按
   staging 超时删除。seal 后的保留/清理属于任务保留策略，是另一套生命周期。
3. **状态转换只有一个边界。** 线上状态由协议模型编解码，SQLite 状态由
   `StorageStateCodec` 编解码；业务代码传 `TransferState`/`FileState`，禁止手写数据库状态字符串。
4. **registry 必须有界并按生命周期释放。** 演示实现默认最多 8 个并发 staging、全局最多
   262,144 条 file/chunk 清单记录；达到上限返回 `RESOURCE_LIMIT`。seal、取消、终态失败释放
   registry；资源超限会清掉该失败提议。可修复的 seal 校验失败不释放，因为发送方仍需补页重试。
5. **断点续传只信接收端已经持久化的 checkpoint。** 发送端的记录只是镜像/展示数据，
   不得覆盖接收端 SQLite 中的 committed 块、`checkpointSeq` 或 `leaseEpoch`。

## SQLite staging 的实现门槛

SQLite 实现至少包含：任务、页种类、页起始索引、规范化页内容/摘要、首次内容时间、seal 状态及
冻结摘要；页写入与幂等判定在同一事务，seal 校验与任务转入 `WAITING_ACCEPT` 原子提交。
重启测试必须覆盖未 seal 补传、已 seal 不受 30 分钟窗口影响、取消/失败清理和 schema 迁移。

在这些测试通过前，台账只能写“进程内演示可用；SQLite staging 未完成”，不能写“支持重启恢复”。

## 影响

- 当前内存实现仍可用于首版演示，但有明确并发/记录上限并在 seal 后释放。
- `StorageStateCodec` 固定现有数据库拼写，防止 Dart enum 改名静默改变磁盘格式。
- 后续 cancel/failure 端点必须调用 registry 生命周期释放；SQLite 实现完成后由持久层承担同一语义。
- 发送端 checkpoint 不得成为恢复依据；任何相反实现或文档都属于阻断发布的正确性缺陷。
