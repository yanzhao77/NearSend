# ADR 0006：二维码图像栈

状态：已接受，平台实机待验证

日期：2026-09-24

## 决策

固定以下依赖，不使用动态范围：

| 依赖 | 许可 | 用途与边界 |
|---|---|---|
| `qr_flutter 4.1.0` | BSD-3-Clause | Flutter 内存中渲染二维码，不保存载荷 |
| `mobile_scanner 7.1.3` | BSD-3-Clause | Android/iOS 摄像头扫码；Android 保持默认 bundled ML Kit，首次离线可用 |
| `zxing2 0.2.4` | BSD-3-Clause | 纯 Dart QR 像素解码，供 Windows 图片导入 |
| `image 4.10.1` | MIT | 有界图片格式解码与像素读取 |
| `qr 3.0.2` | BSD-3-Clause | `qr_flutter` 同版本核心；作为测试直接依赖生成可核对图片 |

压缩图片最大 16 MiB、解码后最大 1600 万像素，CPU 解码在 isolate 执行。Windows 使用系统
`IFileOpenDialog`，读取前检查大小，不记录路径、像素或二维码内容。扫码/导图只返回字符串给
`ScannedPairingPayload` 严格解析，不建立第二套信任规则。

移动摄像头仅接受 QR 格式和单个非空结果；多个或非法值不自动选择。Android 不启用依赖 Google
Play Services 首次下载的 unbundled 模型。相机拒权保留图片/文本路径。

## 验证边界

Flutter QR PNG 往返解码测试通过；iOS Simulator 构建通过。Android 构建连续两次在 Maven 下载
插件 Kotlin 1.8 工件时 TLS 握手中断，未进入插件源码编译。Windows C++ 通道未在 Windows 编译；
摄像头、系统文件选择和实际屏幕扫码仍需目标设备验证。
