# NearSend 1.2 当前环境验收摘要

日期：2026-09-24

分支：`feat/v1.2-upgrade`

工具链：FVM Flutter 3.47.5 / Dart 3.13.4，macOS 主机

## 已执行

| 检查 | 结果 |
|---|---|
| `fvm dart format --output=none --set-exit-if-changed .` | 通过；226 个文件无变化 |
| `fvm flutter analyze` | 通过；无问题 |
| `fvm flutter test --reporter compact` | 通过；1369 项 |
| `fvm flutter build apk --debug` | 通过；首次 Maven TLS 失败后 Flutter 自动重试成功 |
| `fvm flutter build ios --simulator` | 通过；生成 `Runner.app` |
| `fvm flutter build macos --debug` | 不适用；仓库未配置 macOS desktop target |
| `python3 tooling/checks/check_links.py --strict` | 通过；104 个文件、548 个链接 |
| `python3 tooling/checks/check_secrets.py` | 通过；506 个跟踪文件无凭证材料 |
| `python3 tooling/checks/check_ci_workflow.py` | 通过 |
| `python3 -m unittest -v test_probes` | 部分通过；协议/存储 21 项通过，TLS 类受 LibreSSL 限制 |

构建产物未提交到 Git。

## 未执行或未通过

- Windows C++、WinRT BLE、Shell 文件动作和 Windows 自动入网：当前主机不是 Windows。
- Android 与 Windows 双向传输、不同 Wi-Fi、无路由器热点、Android 指定 `Network` socket：缺目标
  双机环境，且指定网络绑定仍是实现阻塞。
- 首次短码 PAKE：没有满足审计、测试向量和 Android/Windows/iOS 支持要求的成熟实现。
- Android SAF/FileProvider 撤权、同名冲突、系统打开/定位和后台切换：缺 Android 真机证据。
- 超过 4 GiB 的完整应用传输、进程重启恢复、IP 改变、身份伪装、过期二维码和热点资源恢复：缺
  目标设备与故障注入环境。
- iOS 真机、后台限制和安全作用域目录：Simulator 构建不能替代真机。
- S0 TLS Python 探针：`/usr/bin/python3` 链接 LibreSSL 2.8.3，`ssl.HAS_TLSv1_3` 为 `False`；没有
  降低 TLS 1.3 最低版本绕过。

## 发布结论

当前分支可提交评审，但不满足正式发布或完整产品验收条件。未经维护者另行操作，不合并 `master`、
不创建版本 tag、不发布 Release。
