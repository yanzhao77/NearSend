import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/app/widgets/near_send_widgets.dart';
import 'package:nearsend/app/application/radar_controller.dart';
import 'package:nearsend/features/home/presentation/connected_device_light.dart';

/// Device connection home for the application shell.
///
/// The page receives read-only presentation facts from the shell. It does not invent a network
/// state or a recoverable task: both values come from the application/session layer.
class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    this.deviceName = 'NearSend',
    this.connectionLabel = '连接状态未知',
    this.connectionTone = NsStatusTone.warning,
    this.hasRecoverableTasks = false,
    this.recoverableTaskCount = 0,
    this.onContinue,
    this.wifiPhase = RadarReadinessPhase.off,
    this.wifiFailureReason,
    this.onWifiReadyChanged,
    this.wifiDevices = const <RadarDevice>[],
    this.bluetoothPhase = RadarReadinessPhase.off,
    this.bluetoothFailureReason,
    this.onBluetoothReadyChanged,
    this.bluetoothDevices = const <RadarDevice>[],
    this.qrSessionDevices = const <RadarDevice>[],
    this.pairedDevices = const <RadarDevice>[],
    this.onRadarDevicePressed,
    this.onScanPairing,
  });

  final String deviceName;
  final String connectionLabel;
  final NsStatusTone connectionTone;
  final bool hasRecoverableTasks;
  final int recoverableTaskCount;
  final VoidCallback? onContinue;
  final RadarReadinessPhase wifiPhase;
  final String? wifiFailureReason;
  final ValueChanged<bool>? onWifiReadyChanged;
  final List<RadarDevice> wifiDevices;
  final RadarReadinessPhase bluetoothPhase;
  final String? bluetoothFailureReason;
  final ValueChanged<bool>? onBluetoothReadyChanged;
  final List<RadarDevice> bluetoothDevices;
  final List<RadarDevice> qrSessionDevices;
  final List<RadarDevice> pairedDevices;
  final ValueChanged<RadarDevice>? onRadarDevicePressed;
  final VoidCallback? onScanPairing;

  static const String connectRoute = '/connect';
  static const String transferRoute = '/transfer';
  static const String emptyStateExplanation = '无需互联网，设备之间仍需建立本地 Wi-Fi 连接。';
  static const String baselineNotice =
      '当前版本会如实展示协议、配对、存储和平台能力；尚未验证或未测量的能力不会显示为已完成。';
  static const String remainingWorkNote = '发送和接收都需要对端设备参与；完成只表示文件已校验并保存。';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('首页')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            return ListView(
              padding: const EdgeInsets.all(NearSendSpacing.lg),
              children: <Widget>[
                _DeviceStatus(
                  deviceName: deviceName,
                  connectionLabel: connectionLabel,
                  tone: connectionTone,
                  onPressed: () => Navigator.of(context).pushNamed('/local-qr'),
                ),
                const SizedBox(height: NearSendSpacing.md),
                _QrSessionSection(
                  devices: qrSessionDevices,
                  onDevicePressed: onRadarDevicePressed,
                ),
                const SizedBox(height: NearSendSpacing.md),
                _VerifiedDevicesSection(
                  devices: pairedDevices,
                  onDevicePressed: onRadarDevicePressed,
                ),
                const SizedBox(height: NearSendSpacing.md),
                if (onScanPairing != null)
                  OutlinedButton.icon(
                    onPressed: onScanPairing,
                    icon: const Icon(Icons.center_focus_weak),
                    label: const Text('扫一扫连接设备'),
                  ),
                const SizedBox(height: NearSendSpacing.md),
                const NsInfoBanner(
                  title: '本地连接说明',
                  message: emptyStateExplanation,
                  tone: NsStatusTone.info,
                ),
                const SizedBox(height: NearSendSpacing.lg),
                _DiscoverySection(
                  switchKey: const ValueKey<String>('wifi-discovery-switch'),
                  title: 'Wi-Fi 局域网连接',
                  enabledMessage: '正在当前局域网发现设备，本机也可被发现',
                  disabledMessage: '已关闭 Wi-Fi 局域网发现',
                  startingMessage: '正在启动 Wi-Fi 局域网发现...',
                  stoppingMessage: '正在关闭 Wi-Fi 局域网发现...',
                  listTitle: '局域网设备',
                  emptyMessage: '暂未在当前局域网发现其他设备',
                  icon: Icons.wifi_outlined,
                  phase: wifiPhase,
                  failureReason: wifiFailureReason,
                  devices: wifiDevices,
                  onReadyChanged: onWifiReadyChanged,
                  onDevicePressed: onRadarDevicePressed,
                ),
                const SizedBox(height: NearSendSpacing.lg),
                _DiscoverySection(
                  switchKey: const ValueKey<String>(
                    'bluetooth-discovery-switch',
                  ),
                  title: '蓝牙连接',
                  enabledMessage: '正在通过蓝牙发现附近设备，本机也可被发现',
                  disabledMessage: '已关闭蓝牙发现',
                  startingMessage: '正在启动蓝牙发现...',
                  stoppingMessage: '正在关闭蓝牙发现...',
                  listTitle: '蓝牙设备',
                  emptyMessage: '暂未发现其他蓝牙设备',
                  icon: Icons.bluetooth,
                  phase: bluetoothPhase,
                  failureReason: bluetoothFailureReason,
                  devices: bluetoothDevices,
                  onReadyChanged: onBluetoothReadyChanged,
                  onDevicePressed: onRadarDevicePressed,
                ),
                if (hasRecoverableTasks) ...<Widget>[
                  const SizedBox(height: NearSendSpacing.xl),
                  NsTaskCard(
                    title: '继续未完成任务',
                    subtitle: '$recoverableTaskCount 个任务可以继续检查或恢复',
                    status: NsTaskStatus.recoverable,
                    statusLabel: '可恢复',
                    onPressed: onContinue,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DiscoverySection extends StatelessWidget {
  const _DiscoverySection({
    required this.switchKey,
    required this.title,
    required this.enabledMessage,
    required this.disabledMessage,
    required this.startingMessage,
    required this.stoppingMessage,
    required this.listTitle,
    required this.emptyMessage,
    required this.icon,
    required this.phase,
    required this.failureReason,
    required this.devices,
    required this.onReadyChanged,
    required this.onDevicePressed,
  });

  final Key switchKey;
  final String title;
  final String enabledMessage;
  final String disabledMessage;
  final String startingMessage;
  final String stoppingMessage;
  final String listTitle;
  final String emptyMessage;
  final IconData icon;
  final RadarReadinessPhase phase;
  final String? failureReason;
  final List<RadarDevice> devices;
  final ValueChanged<bool>? onReadyChanged;
  final ValueChanged<RadarDevice>? onDevicePressed;

  @override
  Widget build(BuildContext context) {
    final bool ready = phase == RadarReadinessPhase.ready;
    final bool busy =
        phase == RadarReadinessPhase.starting ||
        phase == RadarReadinessPhase.stopping;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SwitchListTile(
          key: switchKey,
          contentPadding: EdgeInsets.zero,
          secondary: Icon(icon),
          title: Text(title),
          subtitle: Text(ready ? enabledMessage : disabledMessage),
          value: ready,
          onChanged: busy ? null : onReadyChanged,
        ),
        if (busy || failureReason != null)
          Padding(
            padding: const EdgeInsets.only(bottom: NearSendSpacing.sm),
            child: Text(
              busy
                  ? (phase == RadarReadinessPhase.stopping
                        ? stoppingMessage
                        : startingMessage)
                  : failureReason!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: failureReason == null
                    ? null
                    : Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        if (devices.isNotEmpty) ...<Widget>[
          const SizedBox(height: NearSendSpacing.sm),
          Text(listTitle, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: NearSendSpacing.xs),
          _DeviceList(devices: devices, onDevicePressed: onDevicePressed),
        ] else if (ready) ...<Widget>[
          const SizedBox(height: NearSendSpacing.xs),
          Text(emptyMessage, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
  }
}

class _QrSessionSection extends StatelessWidget {
  const _QrSessionSection({
    required this.devices,
    required this.onDevicePressed,
  });

  final List<RadarDevice> devices;
  final ValueChanged<RadarDevice>? onDevicePressed;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text('本次扫码会话', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: NearSendSpacing.xs),
      if (devices.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: NearSendSpacing.md),
          child: Text('暂无扫码会话。会话到期后会自动移除，不会作为历史设备保存。'),
        )
      else
        _DeviceList(
          devices: devices,
          onDevicePressed: onDevicePressed,
          paired: true,
        ),
    ],
  );
}

class _VerifiedDevicesSection extends StatelessWidget {
  const _VerifiedDevicesSection({
    required this.devices,
    required this.onDevicePressed,
  });

  final List<RadarDevice> devices;
  final ValueChanged<RadarDevice>? onDevicePressed;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text('已验证设备历史', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: NearSendSpacing.xs),
      if (devices.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: NearSendSpacing.md),
          child: Text('暂无已验证的历史设备。显示名称本身不代表可信身份。'),
        )
      else
        _DeviceList(
          devices: devices,
          onDevicePressed: onDevicePressed,
          paired: true,
        ),
    ],
  );
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({
    required this.devices,
    required this.onDevicePressed,
    this.paired = false,
  });

  final bool paired;
  final List<RadarDevice> devices;
  final ValueChanged<RadarDevice>? onDevicePressed;

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      for (final RadarDevice device in devices)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.devices_outlined, size: 24),
          title: Text(
            device.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            semanticsLabel: device.isReady
                ? '${device.name}，已实时验证并就绪'
                : device.name,
          ),
          subtitle: Text(
            device.isRevoked
                ? '已撤销 · ${device.detail}'
                : paired
                ? '${device.isReady ? '已连接' : '未连接'} · ${device.detail}'
                : device.detail,
          ),
          trailing: paired && device.isReady && !device.isRevoked
              ? const ConnectedDeviceLight()
              : const Icon(Icons.chevron_right),
          onTap: onDevicePressed == null
              ? null
              : () => onDevicePressed!(device),
        ),
    ],
  );
}

class _DeviceStatus extends StatelessWidget {
  const _DeviceStatus({
    required this.deviceName,
    required this.connectionLabel,
    required this.tone,
    required this.onPressed,
  });

  final String deviceName;
  final String connectionLabel;
  final NsStatusTone tone;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(NearSendRadii.card),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final Widget identity = Row(
              children: <Widget>[
                const CircleAvatar(child: Icon(Icons.compare_arrows)),
                const SizedBox(width: NearSendSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '本机设备',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      const Text('点击出示连接二维码'),
                      Text(
                        deviceName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
              ],
            );
            return Padding(
              padding: const EdgeInsets.all(NearSendSpacing.md),
              child: constraints.maxWidth < 320
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        identity,
                        const SizedBox(height: NearSendSpacing.sm),
                        NsStatusBadge(label: connectionLabel, tone: tone),
                      ],
                    )
                  : Row(
                      children: <Widget>[
                        Expanded(child: identity),
                        const SizedBox(width: NearSendSpacing.sm),
                        Flexible(
                          child: NsStatusBadge(
                            label: connectionLabel,
                            tone: tone,
                          ),
                        ),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }
}
