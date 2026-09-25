import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nearsend/app/application/radar_controller.dart';
import 'package:nearsend/app/node_session.dart';
import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/features/pairing/presentation/pairing_qr_widgets.dart';

class LocalDeviceQrPage extends StatefulWidget {
  const LocalDeviceQrPage({
    super.key,
    required this.session,
    required this.radar,
    required this.deviceName,
  });
  final NodeSession? session;
  final RadarController radar;
  final String deviceName;

  @override
  State<LocalDeviceQrPage> createState() => _LocalDeviceQrPageState();
}

class _LocalDeviceQrPageState extends State<LocalDeviceQrPage> {
  Timer? _timer;
  final Stopwatch _age = Stopwatch();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _refresh() {
    widget.session?.refreshPairingCode();
    _age
      ..reset()
      ..start();
    setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    _age.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.session, widget.radar]),
    builder: (context, _) {
      final payload = widget.session?.payload;
      final paired =
          payload != null &&
          (widget.session?.node?.pairing.hasPairedClient(payload.sessionId) ??
              false);
      final connected =
          paired &&
          (widget.session?.node?.pairing.pairedClients.any(
                (client) =>
                    client.sessionId == payload.sessionId && client.isRecent,
              ) ??
              false);
      final expired =
          payload != null && _age.elapsed.inSeconds >= payload.expiresInSeconds;
      return Scaffold(
        appBar: AppBar(title: const Text('本机二维码')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(NearSendSpacing.lg),
              children: [
                Text(
                  widget.deviceName,
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: NearSendSpacing.md),
                const Text(
                  '让对方在 NearSend 中扫描下方二维码并确认连接。',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: NearSendSpacing.lg),
                if (connected)
                  const ListTile(
                    leading: Icon(Icons.check_circle_outline),
                    title: Text('设备已连接'),
                    subtitle: Text('返回首页可查看已配对设备，在“传输”栏发送或接收文件。'),
                  )
                else if (paired)
                  const Text('设备已配对，当前未连接。请检查对方设备和本地网络。')
                else if (expired)
                  const Text('二维码已过期，请刷新后重新扫描。')
                else if (payload != null)
                  Center(
                    child: FittedBox(
                      child: PairingQrView(payload: payload.encode()),
                    ),
                  )
                else
                  Text(widget.session?.failureReason ?? '正在准备本机连接信息，请稍候。'),
                const SizedBox(height: NearSendSpacing.md),
                const Text('设备之间需要可用的本地 Wi-Fi 连接，无需互联网。二维码仅用于本次安全配对，请勿公开分享。'),
                const SizedBox(height: NearSendSpacing.md),
                OutlinedButton.icon(
                  onPressed: widget.session?.phase == NodePhase.ready
                      ? _refresh
                      : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新二维码'),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
