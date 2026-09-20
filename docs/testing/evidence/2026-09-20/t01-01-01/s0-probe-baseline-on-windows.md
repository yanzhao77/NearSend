# S0 参考探针在 Windows 上的复现结果与一处可移植性缺陷

- 运行 ID：`t01-01-01`
- 日期：2026-09-20
- 任务：T01-01（工程基线附带的本机基线核对）
- 环境：见同目录 `environment.json`
- 原始日志：`s0-probe-baseline-on-windows.log`（修复前）、`s0-probe-tests-after-utf8-fix.log`（修复后）

## 1. 为什么要跑这一项

`docs/PROJECT_LEDGER.md` §6 记录「导入后执行 `cd tooling/s0 && python3 -m unittest -v test_probes`：24项通过」。
T01-01 要建立可构建、可测试的工程基线，因此在改动前先在本机复现这条既有结论，
确认基线不是只看文档、而是可执行的。

## 2. 结果

| 阶段 | 运行数 | 通过 | 失败 | 未运行 | 退出码 |
| --- | --- | --- | --- | --- | --- |
| 首次运行（原始环境） | 21 | 20 | 1 | 3（`TLSTests` 类 setUpClass 报错，3 个 TLS 用例未执行） | 1 |
| 修复 `openssl` 环境后 | 24 | 23 | 1 | 0 | 1 |
| 修复代码后 | 24 | 24 | 0 | 0 | 0 |

**结论：台账中「24项通过」的结论是在 Linux/UTF-8 环境下成立的；在本机 Windows（locale `cp936`）默认环境下不能直接复现，存在两个独立原因。两者都已定位并处理。**

## 3. 原因一：探针按进程 locale 读取协议向量（已修复）

`s0-probe-baseline-on-windows.log` 的失败：

```text
FAIL: test_fixed_vectors (test_probes.ProtocolTests)
AssertionError: '4c46[90 chars]000017e792a7e58bace69ea12fe5a8b4e5acade798af2e[170 chars]6809'
             != '4c46[90 chars]000011e8b584e696992fe6b58be8af952e747874000000[158 chars]6809'
```

定位：

- `tooling/s0/test_probes.py:25` 使用 `Path(...).read_text()`，**未指定编码**。
- 本机 `locale.getpreferredencoding(False)` 为 `cp936`，因此 `docs/protocol/vectors-v1.json`
  中的中文路径 `资料/测试.txt` 被按 GBK 误解码。
- 字节级核对确认**向量文件本身是正确的 UTF-8**（含 `e8b584e69699`，不含 GBK `d7cac1cf`，无 BOM）。
- 误解码后的字符串重新按 UTF-8 编码得到 23 字节，而规范期望 17 字节，于是 LFTM1 规范化字节串不一致。

同一缺陷类别还影响：

- `tooling/s0/test_probes.py` 读取 `cert.pem`（PEM 为 ASCII，实际未触发，但同属一处模式）；
- `tooling/s0/make_vectors.py` 用 `write_text()` **写出**向量文件——在 cp936 机器上重新生成
  会写出 GBK 字节，与仓库中已提交的 UTF-8 文件不同，破坏「向量可复现」。

修复：为这三处文本 I/O 显式指定 `encoding="utf-8"`。

验证：

- `test_probes` 24/24 通过（日志 `s0-probe-tests-after-utf8-fix.log`）。
- 在 cp936 机器上执行 `python make_vectors.py` 后，
  `docs/protocol/vectors-v1.json` 的 SHA-256 与执行前一致：
  `D66786736789C9A1568F63ADBBFE5A4048E90667260EFFA97A96DD43FDB96CA0`。
  即同一输入在 Windows/cp936 与 Linux/UTF-8 下产生**字节相同**的向量文件。

## 4. 原因二：本机 anaconda 的 openssl CLI 不可用（环境问题，非仓库缺陷）

`TLSTests.setUpClass` 报错：

```text
CalledProcessError: Command '['openssl', 'req', '-x509', ...]' returned non-zero exit status 1
openssl.exe : Can't open D:\bld\openssl_split_1694461107614\_h_env\Library/openssl.cnf for reading
```

- PATH 中的 `openssl` 来自 `C:\data\python\anaconda3\Library\bin\openssl.exe`，
  该二进制硬编码了打包时的构建路径，而本机既没有这个路径，anaconda 目录下也没有随附 `openssl.cnf`。
- 处置：把 Git for Windows 自带的 `E:\Tools\Git\usr\bin` 放到 PATH 前面（`OpenSSL 3.5.7`），
  3 个 TLS 用例即可执行并通过。

**这属于本机环境缺陷，未修改仓库代码。** 它说明 `test_probes` 依赖外部 `openssl` CLI：
在 T01-02 建立 CI 时必须显式固定一个可用的 openssl，或者把自签证书生成改为 Python 内置实现，
否则「24项通过」在别的机器上会再次退化为 21 项。

## 5. 对台账的影响

- `D04`（固定编码/摘要向量）与 `E01`（24 项自动化实验）原有的「已完成」结论**在 Windows 上原先不成立**，
  本次修复后可在 Windows 与 Linux 同时成立；台账已相应补充说明，原始失败日志按规则保留、未被覆盖。
- 修复不改变协议语义、向量内容或任何摘要值；它只修正探针的字符编码处理。

## 6. 已知限制

- 本机 Python 3.10.9 / SQLite 3.40.1 / OpenSSL 3.5.7，与历史证据的
  Python 3.12.14 / SQLite 3.53.1 / OpenSSL 3.5.8 不同；本次只证明这 24 项在该组合下通过，
  不代表与原始环境的逐字节等价性（向量文件本身的 SHA-256 一致）。
- 未重跑 20 GiB、10,000 小文件等高成本实验；源码算法未变，历史原始证据未改动。
- 仍未覆盖真机网络绑定、SAF URI、设备生命周期与生产存储耐久性。
