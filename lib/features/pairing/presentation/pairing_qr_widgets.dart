import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/core/security/bootstrap_pairing_payload.dart';
import 'package:nearsend/platform/platform_permission_gateway.dart';
import 'package:nearsend/platform/qr_image_gateway.dart';

/// A scanner failure that should be returned to the screen that launched it.
class PairingScanFailure {
  const PairingScanFailure(this.message);

  final String message;
}

class PairingQrView extends StatelessWidget {
  const PairingQrView({super.key, required this.payload, this.size = 240});

  final String payload;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'NearSend 配对二维码',
    image: true,
    child: ColoredBox(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(NearSendSpacing.sm),
        child: QrImageView(
          data: payload,
          version: QrVersions.auto,
          errorCorrectionLevel: QrErrorCorrectLevel.M,
          size: size,
          backgroundColor: Colors.white,
          eyeStyle: const QrEyeStyle(color: Colors.black),
          dataModuleStyle: const QrDataModuleStyle(color: Colors.black),
        ),
      ),
    ),
  );
}

class MobilePairingScannerPage extends StatefulWidget {
  const MobilePairingScannerPage({super.key});

  @override
  State<MobilePairingScannerPage> createState() =>
      _MobilePairingScannerPageState();
}

class _MobilePairingScannerPageState extends State<MobilePairingScannerPage> {
  late final MobileScannerController _controller;
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _detected(BarcodeCapture capture) {
    if (_handled) return;
    final List<String> values = capture.barcodes
        .map((Barcode barcode) => barcode.rawValue)
        .whereType<String>()
        .where((String value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (values.isEmpty) return;
    if (values.length != 1) {
      _returnFailure('画面中检测到多个二维码，请只对准对方设备的 NearSend 连接二维码。');
      return;
    }
    try {
      ScannedPairingPayload.parse(values.single);
    } on FormatException catch (error) {
      _returnFailure('扫描到的二维码不是有效的 NearSend 连接码：${error.message}');
      return;
    } on Object {
      _returnFailure('扫描到的二维码不是有效的 NearSend 连接码，请确认对方展示的是连接二维码。');
      return;
    }
    _handled = true;
    Navigator.of(context).pop<Object?>(values.single);
  }

  void _returnFailure(String message) {
    if (_handled) return;
    _handled = true;
    Navigator.of(context).pop<Object?>(PairingScanFailure(message));
  }

  void _scannerFailed(MobileScannerException error) {
    if (_handled) return;
    final String message = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        '相机权限被拒绝，请在系统设置中允许 NearSend 使用相机后重试。',
      MobileScannerErrorCode.unsupported => '当前设备不支持相机扫码，请改用连接信息导入。',
      _ =>
        '相机启动失败（${error.errorCode.name}）：'
            '${error.errorDetails?.message ?? error.errorCode.message}',
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _returnFailure(message);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('扫描配对码')),
    body: SafeArea(
      child: MobileScanner(
        onDetect: _detected,
        controller: _controller,
        errorBuilder: (BuildContext context, MobileScannerException error) {
          _scannerFailed(error);
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(NearSendSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const CircularProgressIndicator(),
                  const SizedBox(height: NearSendSpacing.md),
                  Text(
                    '相机扫码失败：${error.errorCode.message}，正在返回…',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

class PairingImageImportButton extends StatefulWidget {
  const PairingImageImportButton({
    super.key,
    required this.gateway,
    required this.onDecoded,
    this.permissionGateway = const MethodChannelPlatformPermissionGateway(),
  });

  final QrImageGateway gateway;
  final ValueChanged<String> onDecoded;
  final PlatformPermissionGateway permissionGateway;

  @override
  State<PairingImageImportButton> createState() =>
      _PairingImageImportButtonState();
}

class _PairingImageImportButtonState extends State<PairingImageImportButton> {
  bool _busy = false;
  String? _error;

  Future<void> _pick() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final PlatformPermissionState permission = await ensurePlatformPermission(
        widget.permissionGateway,
        PlatformPermissionKind.files,
      );
      if (!permission.allowsUse) {
        if (mounted) {
          setState(() => _error = '无法访问系统文件选择器，请检查系统权限后重试。');
        }
        return;
      }
      final bytes = await widget.gateway.pickImage();
      if (bytes == null) return;
      final String value = await decodeQrImage(bytes);
      ScannedPairingPayload.parse(value);
      widget.onDecoded(value);
    } on Object {
      if (mounted) setState(() => _error = '图片中没有可用的 NearSend 配对码。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      OutlinedButton.icon(
        onPressed: _busy ? null : _pick,
        icon: _busy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.image_search_outlined),
        label: const Text('从图片导入'),
      ),
      if (_error != null) ...<Widget>[
        const SizedBox(height: NearSendSpacing.xs),
        Text(
          _error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ],
    ],
  );
}
