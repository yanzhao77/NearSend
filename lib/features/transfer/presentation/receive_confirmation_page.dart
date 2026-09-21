import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/core/storage/task_authorization_repository.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';

/// The receive confirmation, and the space check that has to come before it.
///
/// `docs/ui/UI_UX_SPEC.md` §5 and `技术方案 V2.1` §16.2 fix what this screen owes the user:
///
/// > 接收前按暂存与导出峰值检查完整空间需求。
///
/// > 空间计划输出每个卷的**解释性明细**……不能只返回布尔值；**不能显示「检查通过」**（当读数未知时）。
///
/// So the page does three things a simpler one would not:
///
/// * it shows **every volume's breakdown**, because "空间不足" without the components is not an
///   answer the user can act on - they cannot tell whether to delete something, or to choose a
///   different location;
/// * it **refuses to accept** when a volume is known to be short, and names the shortfall, because
///   starting a transfer that cannot finish costs the user the bytes already moved;
/// * it **does not treat an unverifiable volume as a pass**. When a provider cannot report its free
///   space the page says so and asks the user to accept that risk explicitly; `unknown` never
///   renders as a green check.
///
/// ## Why the estimate is displayed rather than asserted
///
/// §16.2 says the safety margin is a policy and "不是空间足够的保证" - other applications keep
/// consuming space, so the check is repeated before each file and before export. The page therefore
/// renders the planner's own reason lines instead of restating the numbers, so what the user
/// approves is what the planner explained.
class ReceiveConfirmationPage extends StatelessWidget {
  const ReceiveConfirmationPage({
    super.key,
    required this.fileCount,
    required this.totalBytes,
    required this.estimate,
    this.saveLocationLabel,
    this.onAccept,
    this.onReject,
  });

  /// Files in the frozen manifest (§6 makes the sealed manifest the authority for this).
  final int fileCount;

  /// The manifest's total, as [TransferProgress] also requires it to be.
  final int totalBytes;

  /// The space plan the planner produced, or null when this side is not the receiver and so has
  /// nothing to measure.
  final SpaceEstimateSnapshot? estimate;

  /// A display label for where the copy will land. Never a full local path.
  final String? saveLocationLabel;

  final VoidCallback? onAccept;
  final VoidCallback? onReject;

  /// The verdict the screen acts on, or null when no estimate was taken.
  SpaceVerdict? get verdict => estimate?.verdict;

  /// Whether acceptance is blocked by a **known** shortfall.
  ///
  /// Deliberately not blocked for [SpaceVerdict.unknown]: §16.1 wants that surfaced and confirmed,
  /// not silently refused, and refusing it would make an unreadable volume behave like a full one.
  bool get isBlocked => verdict == SpaceVerdict.insufficient;

  /// Whether the user is being asked to accept an unverified risk.
  bool get needsRiskAcknowledgement => verdict == SpaceVerdict.unknown;

  /// The status line, which must never read as a pass when nothing was verified.
  String get spaceStatusLabel => switch (verdict) {
    SpaceVerdict.sufficient => '空间检查通过（仍受 §16.2 的策略余量约束，不是保证）',
    SpaceVerdict.insufficient => '空间不足，无法接收',
    SpaceVerdict.unknown => '无法确认可用空间，需要你确认风险',
    null => '未做空间检查',
  };

  @override
  Widget build(BuildContext context) {
    final NearSendColors palette = NearSendColors.of(
      Theme.of(context).brightness,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('接收确认')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: NearSendSizing.formMaxWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.all(NearSendSpacing.lg),
              children: <Widget>[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(NearSendSpacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '对方想要发送',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: NearSendSpacing.sm),
                        _Row(label: '文件数', value: '$fileCount'),
                        _Row(label: '总大小', value: formatBytes(totalBytes)),
                        if (saveLocationLabel != null)
                          _Row(label: '保存位置', value: saveLocationLabel!),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: NearSendSpacing.lg),
                _SpaceSection(
                  estimate: estimate,
                  palette: palette,
                  statusLabel: spaceStatusLabel,
                ),
                const SizedBox(height: NearSendSpacing.xl),
                if (isBlocked)
                  FilledButton.icon(
                    // Refused rather than offered: starting a transfer that cannot finish costs
                    // the user the bytes already moved, and §11 pairs SPACE_INSUFFICIENT with
                    // "free space or change the location" rather than with a retry.
                    onPressed: null,
                    icon: const Icon(Icons.block),
                    label: const Text('空间不足，先清理或更换位置'),
                  )
                else
                  FilledButton.icon(
                    onPressed: onAccept,
                    icon: const Icon(Icons.check),
                    label: Text(needsRiskAcknowledgement ? '已知晓风险，仍然接收' : '接收'),
                  ),
                const SizedBox(height: NearSendSpacing.sm),
                OutlinedButton.icon(
                  onPressed: onReject,
                  icon: const Icon(Icons.close),
                  label: const Text('拒绝'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SpaceSection extends StatelessWidget {
  const _SpaceSection({
    required this.estimate,
    required this.palette,
    required this.statusLabel,
  });

  final SpaceEstimateSnapshot? estimate;
  final NearSendColors palette;
  final String statusLabel;

  @override
  Widget build(BuildContext context) {
    final SpaceEstimateSnapshot? snapshot = estimate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              switch (snapshot?.verdict) {
                SpaceVerdict.sufficient => Icons.check_circle_outline,
                SpaceVerdict.insufficient => Icons.error_outline,
                SpaceVerdict.unknown => Icons.help_outline,
                null => Icons.info_outline,
              },
              color: switch (snapshot?.verdict) {
                SpaceVerdict.sufficient => palette.primary,
                SpaceVerdict.insufficient => palette.error,
                _ => palette.warning,
              },
            ),
            const SizedBox(width: NearSendSpacing.sm),
            Expanded(
              child: Text(
                statusLabel,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ],
        ),
        if (snapshot != null) ...<Widget>[
          const SizedBox(height: NearSendSpacing.sm),
          for (final SpaceVolumeSnapshot volume in snapshot.volumes)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(NearSendSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      volume.volumeRef,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: NearSendSpacing.xs),
                    // The planner's own explanations, rendered rather than summarised: §16.2 asks
                    // for the breakdown, and a total the user cannot decompose is a total they
                    // cannot act on.
                    for (final SpaceLineSnapshot line in volume.lines)
                      Padding(
                        padding: const EdgeInsets.only(
                          bottom: NearSendSpacing.xxs,
                        ),
                        child: Text(
                          '${formatBytes(line.bytes)} — ${line.reason}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    if (volume.shortfallBytes != null)
                      Padding(
                        padding: const EdgeInsets.only(
                          top: NearSendSpacing.xxs,
                        ),
                        child: Text(
                          '还差 ${formatBytes(volume.shortfallBytes!)}',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: palette.error),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

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
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
