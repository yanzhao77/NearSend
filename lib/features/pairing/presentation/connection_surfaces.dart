import 'package:flutter/material.dart';

import 'package:nearsend/app/application/pairing_coordinator.dart';
import 'package:nearsend/core/security/bootstrap_pairing_payload.dart';
import 'package:nearsend/features/pairing/presentation/pairing_qr_widgets.dart';
import 'package:nearsend/platform/platform_permission_gateway.dart';
import 'package:nearsend/platform/qr_image_gateway.dart';

class PairingProgressDialog extends StatelessWidget {
  const PairingProgressDialog({
    super.key,
    required this.coordinator,
    required this.onCancel,
  });
  final PairingCoordinator coordinator;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) onCancel();
    },
    child: ListenableBuilder(
      listenable: coordinator,
      builder: (_, _) => AlertDialog(
        title: const Text('正在连接'),
        content: Row(
          children: [
            const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                coordinator.stage == PairingStage.joiningNetwork
                    ? '正在加入本地网络'
                    : '正在验证设备身份并建立连接',
              ),
            ),
          ],
        ),
        actions: [TextButton(onPressed: onCancel, child: const Text('取消连接'))],
      ),
    ),
  );
}

/// Only this explicitly chosen settings page exposes the manual payload field.
class AdvancedConnectionPage extends StatefulWidget {
  const AdvancedConnectionPage({
    super.key,
    required this.onConnect,
    required this.failureReason,
    this.qrImageGateway,
    this.permissionGateway = const MethodChannelPlatformPermissionGateway(),
  });
  final Future<bool> Function(BuildContext, ScannedPairingPayload) onConnect;
  final String? Function() failureReason;
  final QrImageGateway? qrImageGateway;
  final PlatformPermissionGateway permissionGateway;

  @override
  State<AdvancedConnectionPage> createState() => _AdvancedConnectionPageState();
}

class _AdvancedConnectionPageState extends State<AdvancedConnectionPage> {
  final _text = TextEditingController();
  ScannedPairingPayload? _payload;
  String? _error;
  bool _busy = false;

  void _parse(String value) {
    try {
      final payload = value.trim().isEmpty
          ? null
          : ScannedPairingPayload.parse(value.trim());
      setState(() {
        _payload = payload;
        _error = null;
      });
    } on Object {
      setState(() {
        _payload = null;
        _error = '连接信息格式无效，请重新复制对方的完整连接信息。';
      });
    }
  }

  Future<void> _connect() async {
    if (_busy || _payload == null) return;
    setState(() => _busy = true);
    final route = ModalRoute.of(context);
    try {
      final connected = await widget.onConnect(context, _payload!);
      if (!mounted) return;
      if (connected) {
        _text.clear();
        if (route != null && route.isActive) {
          Navigator.of(context).removeRoute(route);
        }
      } else {
        setState(() => _error = widget.failureReason());
      }
    } on Object {
      if (mounted) setState(() => _error = '连接未能完成，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('高级连接')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text('用于无法扫码时连接设备。粘贴对方的连接信息，系统仍会验证设备身份。'),
            const SizedBox(height: 16),
            TextField(
              controller: _text,
              enabled: !_busy,
              maxLines: 5,
              minLines: 3,
              decoration: const InputDecoration(labelText: '对方连接信息'),
              onChanged: _parse,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _payload == null || _busy ? null : _connect,
              child: const Text('连接'),
            ),
            if (widget.qrImageGateway != null && !_busy) ...[
              const SizedBox(height: 16),
              PairingImageImportButton(
                gateway: widget.qrImageGateway!,
                permissionGateway: widget.permissionGateway,
                onDecoded: (value) {
                  _text.text = value;
                  _parse(value);
                },
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class ConnectedDeviceCard extends StatelessWidget {
  const ConnectedDeviceCard({
    super.key,
    required this.name,
    required this.status,
    required this.activeTasks,
    this.onDisconnect,
    this.onCheck,
    this.onPair,
  });
  final String name;
  final String status;
  final int activeTasks;
  final VoidCallback? onDisconnect;
  final VoidCallback? onCheck;
  final VoidCallback? onPair;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('设备连接', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          Text(name, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(status),
          Text('相关活动任务：$activeTasks'),
          const SizedBox(height: 16),
          if (onCheck != null)
            OutlinedButton(onPressed: onCheck, child: const Text('检查连接')),
          if (onPair != null)
            OutlinedButton(onPressed: onPair, child: const Text('重新扫码配对')),
          if (onDisconnect != null)
            FilledButton.icon(
              onPressed: onDisconnect,
              icon: const Icon(Icons.link_off),
              label: const Text('断开连接'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    ),
  );
}
