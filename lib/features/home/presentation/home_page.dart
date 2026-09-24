import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/app/widgets/near_send_widgets.dart';
import 'package:nearsend/app/application/radar_controller.dart';

/// The first screen for the four-section application shell.
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
    this.radarReady = false,
    this.radarBusy = false,
    this.radarFailureReason,
    this.onRadarReadyChanged,
    this.radarDevices = const <RadarDevice>[],
    this.onRadarDevicePressed,
  });

  final String deviceName;
  final String connectionLabel;
  final NsStatusTone connectionTone;
  final bool hasRecoverableTasks;
  final int recoverableTaskCount;
  final VoidCallback? onContinue;
  final bool radarReady;
  final bool radarBusy;
  final String? radarFailureReason;
  final ValueChanged<bool>? onRadarReadyChanged;
  final List<RadarDevice> radarDevices;
  final ValueChanged<RadarDevice>? onRadarDevicePressed;

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
            final bool wide = constraints.maxWidth >= 700;
            final List<Widget> actions = <Widget>[
              _ActionCard(
                icon: Icons.north_east,
                title: '发送文件',
                message: '选择文件，连接本地设备并等待对方确认。',
                onPressed: () =>
                    Navigator.of(context)
                        .pushNamed(connectRoute, arguments: 'send'),
              ),
              _ActionCard(
                icon: Icons.south,
                title: '接收文件',
                message: '查看对方提供的文件，确认位置后接收并保存。',
                onPressed: () =>
                    Navigator.of(context)
                        .pushNamed(connectRoute, arguments: 'receive'),
              ),
            ];
            return ListView(
              padding: const EdgeInsets.all(NearSendSpacing.lg),
              children: <Widget>[
                _DeviceStatus(
                  deviceName: deviceName,
                  connectionLabel: connectionLabel,
                  tone: connectionTone,
                ),
                const SizedBox(height: NearSendSpacing.md),
                const NsInfoBanner(
                  title: '本地连接说明',
                  message: emptyStateExplanation,
                  tone: NsStatusTone.info,
                ),
                const SizedBox(height: NearSendSpacing.md),
                const NsInfoBanner(
                  title: '当前能力状态',
                  message: baselineNotice,
                  tone: NsStatusTone.warning,
                ),
                const SizedBox(height: NearSendSpacing.xl),
                Text('开始传输', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: NearSendSpacing.sm),
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(child: actions[0]),
                      const SizedBox(width: NearSendSpacing.md),
                      Expanded(child: actions[1]),
                    ],
                  )
                else ...<Widget>[
                  actions[0],
                  const SizedBox(height: NearSendSpacing.sm),
                  actions[1],
                ],
                const SizedBox(height: NearSendSpacing.sm),
                Text(
                  remainingWorkNote,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: NearSendSpacing.lg),
                _RadarSection(
                  ready: radarReady,
                  busy: radarBusy,
                  failureReason: radarFailureReason,
                  devices: radarDevices,
                  onReadyChanged: onRadarReadyChanged,
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

class _RadarSection extends StatelessWidget {
  const _RadarSection({
    required this.ready,
    required this.busy,
    required this.failureReason,
    required this.devices,
    required this.onReadyChanged,
    required this.onDevicePressed,
  });

  final bool ready;
  final bool busy;
  final String? failureReason;
  final List<RadarDevice> devices;
  final ValueChanged<bool>? onReadyChanged;
  final ValueChanged<RadarDevice>? onDevicePressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('附近设备雷达'),
          subtitle: Text(ready ? '本机可被发现并接受连接' : '已关闭发现和就绪状态'),
          value: ready,
          onChanged: busy ? null : onReadyChanged,
        ),
        if (busy || failureReason != null)
          Padding(
            padding: const EdgeInsets.only(bottom: NearSendSpacing.sm),
            child: Text(
              busy
                  ? (ready ? '正在关闭附近设备雷达...' : '正在启动附近设备雷达...')
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
          Text('附近与历史设备', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: NearSendSpacing.xs),
          for (final RadarDevice device in devices)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: SizedBox.square(
                dimension: 24,
                child: device.isReady
                    ? Center(
                        child: Semantics(
                          label: '已实时验证并就绪',
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: const BoxDecoration(
                              color: Color(0xFF16835D),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      )
                    : const Icon(Icons.devices_outlined, size: 20),
              ),
              title: Text(
                device.name,
                semanticsLabel: device.isReady
                    ? '${device.name}，已实时验证并就绪'
                    : device.name,
              ),
              subtitle: Text(
                device.isRevoked ? '已撤销 · ${device.detail}' : device.detail,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: onDevicePressed == null
                  ? null
                  : () => onDevicePressed!(device),
            ),
        ],
      ],
    );
  }
}

class _DeviceStatus extends StatelessWidget {
  const _DeviceStatus({
    required this.deviceName,
    required this.connectionLabel,
    required this.tone,
  });

  final String deviceName;
  final String connectionLabel;
  final NsStatusTone tone;

  @override
  Widget build(BuildContext context) {
    return Card(
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
                    Text('本机设备', style: Theme.of(context).textTheme.labelSmall),
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
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.message,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String message;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(NearSendRadii.card),
        child: Padding(
          padding: const EdgeInsets.all(NearSendSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                icon,
                size: 32,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: NearSendSpacing.sm),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: NearSendSpacing.xs),
              Text(message, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: NearSendSpacing.md),
              NsPrimaryButton(
                label: title == '发送文件' ? '发送' : '接收',
                icon: icon,
                onPressed: onPressed,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
