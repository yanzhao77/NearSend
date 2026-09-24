# NearSend 1.2 当前环境验收摘要

日期：2026-09-24

分支：`feat/v1.2-upgrade`

工具链：FVM Flutter 3.47.5 / Dart 3.13.4，macOS 主机

## 已执行

| 检查 | 结果 |
|---|---|
| `fvm dart format --output=none --set-exit-if-changed .` | 通过；229 个文件无变化 |
| `fvm flutter analyze` | 通过；无问题 |
| `fvm flutter test --reporter compact` | 通过；1386 项 |
| 雷达对端信息定向测试 | 通过；26 项，覆盖设备名/平台、按渠道分列、IPv6 地址及所选对端路由 |
| 雷达修复 Android APK | 构建通过；25102RKBEC / Android 17 上授权卸载不同签名旧包后安装 `versionCode 13` 成功，冷启动正常 |
| Wi-Fi/蓝牙入口拆分定向测试 | 通过；26 项，覆盖独立开关、列表归属、名称、点击、后台释放和 200% 字体窄屏布局 |
| 拆分入口 Android APK | 部分实机通过；独立 Wi-Fi/蓝牙区域渲染正常且无可见溢出，日志无 Flutter/Android 致命异常；卸载旧包导致应用数据清除，双设备与完整交互未验证 |
| `fvm flutter build apk --debug` | 通过；首次 Maven TLS 失败后 Flutter 自动重试成功 |
| `fvm flutter build ios --simulator` | 通过；生成 `Runner.app` |
| `fvm flutter build macos --debug` | 不适用；仓库未配置 macOS desktop target |
| `python3 tooling/checks/check_links.py --strict` | 通过；105 个 Markdown 文件、548 个链接无断链 |
| `python3 tooling/checks/check_secrets.py` | 通过；506 个跟踪文件无凭证材料 |
| `python3 tooling/checks/check_ci_workflow.py` | 通过 |
| `python3 -m unittest -v test_probes` | 部分通过；协议/存储 21 项通过，TLS 类受 LibreSSL 限制 |
| PR #68 CI Android 构建 | 通过；run `35961072170` 构建 debug/release APK |
| PR #68 CI Windows release 构建 | 通过；首轮 STL1011 失败后由 `d9e02e0` 修复，run `35961651508` 编译和链接成功 |
| Android 摄像头运行时权限 | Xiaomi M2104K10AC / Android 13 / MIUI 14 真机通过首次请求、拒绝阻断、允许后预览和重复扫码复查 |
| Android SAF 目录授权 | 真机通过系统选择与确认；读写 tree URI 为 `persisted=0x3`，应用进程重启后仍有效；未申请广泛存储权限 |

构建产物未提交到 Git。

## 未执行或未通过

- Windows C++、WinRT BLE、DPAPI、图片导入和 Shell 文件动作已通过 CI 编译；BLE/WLAN/选择器/Shell
  交互及 Windows 自动入网仍缺 Windows 10/11 主机证据，自动入网能力继续诚实报告不支持。
- Android 与 Windows 双向传输、不同 Wi-Fi、无路由器热点、Android 指定 `Network` socket：缺目标
  双机环境，且指定网络绑定仍是实现阻塞。
- 雷达设备名称与所选对端信息已有自动化覆盖；当前只有一台 Android 设备，真实 mDNS/BLE 名称发现、
  同实例按渠道分列和跨设备点击连接未执行。
- Wi-Fi 与蓝牙入口已在代码和自动化中独立；25102RKBEC / Android 17 已验证两个区域可见且布局
  正常，但当前只有一台设备，BLE 广播名称、真实设备点击连接和两开关互不影响的完整人工操作仍未执行。
- 首次短码 PAKE：没有满足审计、测试向量和 Android/Windows/iOS 支持要求的成熟实现。
- Android SAF/FileProvider 撤权、真实文件读写、同名冲突、系统打开/定位和后台切换仍未执行；
  系统目录选择、持久授权和应用进程重启后的授权恢复已有 Android 真机证据。
- 超过 4 GiB 的完整应用传输、进程重启恢复、IP 改变、身份伪装、过期二维码和热点资源恢复：缺
  目标设备与故障注入环境。
- iOS 真机、后台限制和安全作用域目录：Simulator 构建不能替代真机。
- S0 TLS Python 探针：`/usr/bin/python3` 链接 LibreSSL 2.8.3，`ssl.HAS_TLSv1_3` 为 `False`；没有
  降低 TLS 1.3 最低版本绕过。

## 发布结论

当前分支可提交评审，但不满足正式发布或完整产品验收条件。未经维护者另行操作，不合并 `master`、
不创建版本 tag、不发布 Release。
