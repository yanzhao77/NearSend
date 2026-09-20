# S0 参考探针

本目录包含 Linux 上执行过的 Python 参考实验，不是 Flutter 产品代码。生产方案仍为 Flutter + 原生适配，尚无可安装客户端。

## 入口

- [项目台账](../../docs/PROJECT_LEDGER.md)
- [协议草案](../../docs/protocol/v1.0-draft1.md)
- [固定测试向量](../../docs/protocol/vectors-v1.json)
- [S0 报告与真机执行单](../../docs/testing/S0-report.md)
- [原始证据](../../docs/testing/evidence/2026-09-20/)

## 运行

已验证环境：Linux、Python 3.12、OpenSSL 命令可用；仅使用 Python 标准库。

在仓库根目录执行：

```bash
cd tooling/s0
python3 -m unittest -v test_probes
mkdir -p evidence
python3 small_files_probe.py
python3 large_file_probe.py --gib 1 --output evidence/large-1gib.json
python3 large_file_probe.py --gib 20 --output evidence/large-20gib.json
```

24项检查涵盖清单向量、输入边界、路径词法、数量上限、子进程突然退出、损坏块修复、旧写入世代拒绝及本机TLS指纹。`resource`与`st_blocks`统计采用Linux口径，不能直接作为跨平台性能结论。

20GiB探针需至少25GiB空闲空间，真实写入并回读，不是稀疏文件占位。每次独立执行，不要同时运行两个大文件探针。正常结束自动清理；异常强杀可能留下large-probe-*目录，清理前核实来源。新结果保存在本目录已忽略的evidence/，审核并标注环境后再归档到docs/testing/。

TLS探针只监听127.0.0.1随机端口，临时证书及私钥测试结束即清理。测试专用连接先验证精确DER指纹再发送HTTP；不允许将其证书策略用作产品的全局信任覆盖。

## 源码职责

| 文件 | 职责 |
| --- | --- |
| protocol_core.py | LFTM1/LFTC1编码、整数及路径词法检查 |
| storage_probe.py | 单文件SQLite WAL/FULL、fsync及epoch参考 |
| test_probes.py | 24项自动化检查 |
| large_file_probe.py | 1/20GiB本地落盘、回读及内存记录 |
| small_files_probe.py | 本地小文件集合与空文件检查 |
| make_vectors.py | 协议维护者生成向量；验证前不要运行覆盖期望值 |

## 覆盖边界

本包没有完整pair/resume HTTP API、二维码、移动端网络适配或安全存储；每块独立提交，未实现生产批量checkpoint/背压。子进程退出不等于设备断电。20GiB探针不经网络、不含SQLite任务队列和导出。小文件探针不含UI、网络和多文件任务语义。Python向量仍需独立Dart/原生实现比对。

## 本次导入

只调整测试向量的仓库路径，未改变协议算法和原始实验数值；原始24项日志与导入后24项复测日志分别保留。大文件和小文件统计沿用已执行证据，本次没有重复高成本实验。安全配对、实际文件写入和checkpoint仍需人工重点复核。
