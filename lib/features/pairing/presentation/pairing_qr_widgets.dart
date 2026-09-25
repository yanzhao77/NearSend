import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/core/security/bootstrap_pairing_payload.dart';
import 'package:nearsend/platform/platform_permission_gateway.dart';
import 'package:nearsend/platform/qr_image_gateway.dart';

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
  bool _retryingCamera = false;

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
    if (values.length != 1) return;
    try {
      ScannedPairingPayload.parse(values.single);
    } on Object {
      return;
    }
    _handled = true;
    Navigator.of(context).pop<String>(values.single);
  }

  Future<void> _retryCamera() async {
    if (_retryingCamera) return;
    setState(() => _retryingCamera = true);
    try {
      // MobileScannerController.start rechecks native camera authorization and
      // requests it when missing.
      await _controller.start();
    } on Object {
      // The controller exposes the failure to MobileScanner's errorBuilder.
    } finally {
      if (mounted) setState(() => _retryingCamera = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('扫描配对码')),
    body: SafeArea(
      child: MobileScanner(
        onDetect: _detected,
        controller: _controller,
        errorBuilder: (BuildContext context, MobileScannerException _) =>
            Center(
              child: Padding(
                padding: const EdgeInsets.all(NearSendSpacing.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Text(
                      '需要相机权限才能扫码。请在系统弹窗中批准；如果系统不再弹出，请到系统设置中开启权限。',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: NearSendSpacing.md),
                    FilledButton.icon(
                      onPressed: _retryingCamera ? null : _retryCamera,
                      icon: _retryingCamera
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.camera_alt_outlined),
                      label: Text(_retryingCamera ? '正在申请相机权限' : '重新申请相机权限'),
                    ),
                  ],
                ),
              ),
            ),
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
