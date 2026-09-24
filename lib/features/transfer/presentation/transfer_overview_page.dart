import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/app/widgets/near_send_widgets.dart';

/// Sending and receiving share the existing secure connection routes.
class TransferOverviewPage extends StatelessWidget {
  const TransferOverviewPage({super.key, this.onSend, this.onReceive});
  final VoidCallback? onSend;
  final VoidCallback? onReceive;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('传输')),
    body: LayoutBuilder(
      builder: (context, constraints) {
        final actions = <Widget>[
          _ActionCard(
            icon: Icons.north_east,
            title: '发送文件',
            message: '选择文件，连接本地设备并等待对方确认。',
            onPressed:
                onSend ??
                () =>
                    Navigator.of(context)
                        .pushNamed('/connect', arguments: 'send'),
          ),
          _ActionCard(
            icon: Icons.south,
            title: '接收文件',
            message: '查看对方提供的文件，确认位置后接收并保存。',
            onPressed:
                onReceive ??
                () =>
                    Navigator.of(context)
                        .pushNamed('/connect', arguments: 'receive'),
          ),
        ];
        return ListView(
          padding: const EdgeInsets.all(NearSendSpacing.lg),
          children: [
            Text('开始传输', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: NearSendSpacing.md),
            if (constraints.maxWidth >= 700)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: actions[0]),
                  const SizedBox(width: NearSendSpacing.md),
                  Expanded(child: actions[1]),
                ],
              )
            else ...[
              actions[0],
              const SizedBox(height: NearSendSpacing.md),
              actions[1],
            ],
            const SizedBox(height: NearSendSpacing.md),
            const Text('发送和接收都需要对端设备参与；完成只表示文件已校验并保存。'),
          ],
        );
      },
    ),
  );
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
