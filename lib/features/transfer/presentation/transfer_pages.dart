import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';

class TransferDetailPage extends StatelessWidget {
  const TransferDetailPage({
    super.key,
    required this.progress,
    this.fileName,
    this.onPause,
    this.onResume,
    this.onCancel,
    this.onRetry,
  });

  final TransferProgress progress;

  /// The file's display name, when there is one.
  final String? fileName;

  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onCancel;
  final VoidCallback? onRetry;

  /// The phase's own words, shown as the primary status.
  String get statusLabel => progress.phase.label;

  /// Whether a determinate progress bar can be drawn.
  bool get hasKnownTotal => progress.fraction != null;

  @override
  Widget build(BuildContext context) {
    final NearSendColors palette = NearSendColors.of(
      Theme.of(context).brightness,
    );

    return Scaffold(
      appBar: AppBar(title: Text(fileName ?? '传输详情')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: NearSendSizing.formMaxWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.all(NearSendSpacing.lg),
              children: <Widget>[
                Text(
                  statusLabel,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: NearSendSpacing.md),
                if (hasKnownTotal)
                  LinearProgressIndicator(value: progress.fraction)
                else
                  // No total yet: an indeterminate bar is honest, and a swept determinate one
                  // would claim a proportion nobody knows.
                  const LinearProgressIndicator(),
                const SizedBox(height: NearSendSpacing.md),
                _Stat(label: '已传 / 总量', value: progress.byteLabel),
                _Stat(label: '速度', value: progress.speedLabel),
                _Stat(label: '剩余时间', value: progress.remainingLabel),
                if (progress.isStalled)
                  Padding(
                    padding: const EdgeInsets.only(top: NearSendSpacing.sm),
                    child: Text(
                      '当前没有进展：连接可能已中断，或对端暂停了任务。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (progress.failureReason != null)
                  Padding(
                    padding: const EdgeInsets.only(top: NearSendSpacing.sm),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(NearSendSpacing.md),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Icon(Icons.error_outline, color: palette.error),
                            const SizedBox(width: NearSendSpacing.sm),
                            Expanded(
                              child: Text(
                                progress.failureReason!,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: NearSendSpacing.xl),
                ..._controls(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _controls(BuildContext context) {
    final List<Widget> controls = <Widget>[];
    if (progress.phase.canInterrupt && onPause != null) {
      controls.add(
        FilledButton.tonalIcon(
          onPressed: onPause,
          icon: const Icon(Icons.pause),
          label: const Text('暂停'),
        ),
      );
    }
    if (progress.phase == TransferPhase.paused && onResume != null) {
      controls.add(
        FilledButton.icon(
          onPressed: onResume,
          icon: const Icon(Icons.play_arrow),
          label: const Text('继续'),
        ),
      );
    }
    if (progress.phase == TransferPhase.failed && onRetry != null) {
      controls.add(
        FilledButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      );
    }
    if (progress.phase.canInterrupt && onCancel != null) {
      controls.add(
        OutlinedButton.icon(
          onPressed: onCancel,
          icon: const Icon(Icons.close),
          label: const Text('取消'),
        ),
      );
    }
    if (controls.isEmpty) {
      return const <Widget>[];
    }
    return <Widget>[
      for (int i = 0; i < controls.length; i++) ...<Widget>[
        if (i > 0) const SizedBox(height: NearSendSpacing.sm),
        SizedBox(width: double.infinity, child: controls[i]),
      ],
    ];
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NearSendSpacing.xxs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
