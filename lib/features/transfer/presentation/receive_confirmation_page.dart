import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/app/widgets/near_send_widgets.dart';
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
class ReceiveConfirmationPage extends StatefulWidget {
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
  State<ReceiveConfirmationPage> createState() =>
      _ReceiveConfirmationPageState();
}

class _ReceiveConfirmationPageState extends State<ReceiveConfirmationPage> {
  bool _riskAcknowledged = false;

  SpaceVerdict? get verdict => widget.estimate?.verdict;

  bool get isBlocked => verdict == SpaceVerdict.insufficient;

  bool get needsRiskAcknowledgement => verdict == SpaceVerdict.unknown;

  String get spaceStatusLabel => switch (verdict) {
    SpaceVerdict.sufficient => '空间检查通过（仍受 §16.2 的策略余量约束，不是保证）',
    SpaceVerdict.insufficient => '空间不足，无法接收',
    SpaceVerdict.unknown => '无法确认可用空间，需要你确认风险',
    null => '未做空间检查',
  };

  @override
  Widget build(BuildContext context) {
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
                        _Row(label: '文件数', value: '${widget.fileCount}'),
                        _Row(
                          label: '总大小',
                          value: formatBytes(widget.totalBytes),
                        ),
                        if (widget.saveLocationLabel != null)
                          _Row(label: '保存位置', value: widget.saveLocationLabel!),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: NearSendSpacing.lg),
                _SpaceSection(
                  estimate: widget.estimate,
                  statusLabel: spaceStatusLabel,
                ),
                const SizedBox(height: NearSendSpacing.xl),
                if (isBlocked)
                  const NsInfoBanner(
                    title: '空间不足，无法接收',
                    message: '请先清理空间或更换保存位置。',
                    tone: NsStatusTone.error,
                  ),
                if (needsRiskAcknowledgement) ...<Widget>[
                  const NsInfoBanner(
                    title: '空间未知',
                    message: '无法确认此位置的可用空间，传输中仍可能失败。',
                    tone: NsStatusTone.warning,
                  ),
                  CheckboxListTile(
                    value: _riskAcknowledged,
                    onChanged: (bool? value) =>
                        setState(() => _riskAcknowledged = value ?? false),
                    title: const Text('我知道空间无法确认，仍承担传输失败的风险'),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
                NsPrimaryButton(
                  onPressed:
                      isBlocked ||
                          (needsRiskAcknowledgement && !_riskAcknowledged)
                      ? null
                      : widget.onAccept,
                  icon: Icons.save_outlined,
                  label: '接收并保存',
                ),
                const SizedBox(height: NearSendSpacing.sm),
                NsSecondaryButton(
                  onPressed: widget.onReject,
                  icon: Icons.close,
                  label: '拒绝',
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
  const _SpaceSection({required this.estimate, required this.statusLabel});

  final SpaceEstimateSnapshot? estimate;
  final String statusLabel;

  @override
  Widget build(BuildContext context) {
    final SpaceEstimateSnapshot? snapshot = estimate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        NsInfoBanner(
          title: '空间预检',
          message: statusLabel,
          tone: _tone(snapshot?.verdict),
        ),
        if (snapshot != null) ...<Widget>[
          const SizedBox(height: NearSendSpacing.sm),
          for (final SpaceVolumeSnapshot volume in snapshot.volumes)
            Padding(
              padding: const EdgeInsets.only(bottom: NearSendSpacing.sm),
              child: NsSpaceBreakdown(
                title: volume.volumeRef,
                status: _spaceStatus(volume.verdict),
                statusLabel: _volumeStatusLabel(volume.verdict),
                lines: <NsSpaceLine>[
                  NsSpaceLine(
                    label: '需要',
                    value: formatBytes(volume.requiredBytes),
                  ),
                  NsSpaceLine(
                    label: '可用',
                    value: volume.freeBytes == null
                        ? '未知'
                        : formatBytes(volume.freeBytes!),
                  ),
                  for (final SpaceLineSnapshot line in volume.lines)
                    NsSpaceLine(
                      label: line.reason,
                      value: formatBytes(line.bytes),
                    ),
                ],
                shortfallLabel: volume.shortfallBytes == null
                    ? null
                    : '还差 ${formatBytes(volume.shortfallBytes!)}',
              ),
            ),
        ],
      ],
    );
  }

  static NsStatusTone _tone(SpaceVerdict? verdict) => switch (verdict) {
    SpaceVerdict.sufficient => NsStatusTone.success,
    SpaceVerdict.insufficient => NsStatusTone.error,
    SpaceVerdict.unknown || null => NsStatusTone.warning,
  };

  static NsSpaceStatus _spaceStatus(SpaceVerdict verdict) => switch (verdict) {
    SpaceVerdict.sufficient => NsSpaceStatus.sufficient,
    SpaceVerdict.insufficient => NsSpaceStatus.insufficient,
    SpaceVerdict.unknown => NsSpaceStatus.unknown,
  };

  static String _volumeStatusLabel(SpaceVerdict verdict) => switch (verdict) {
    SpaceVerdict.sufficient => '空间充足',
    SpaceVerdict.insufficient => '空间不足',
    SpaceVerdict.unknown => '无法确认',
  };
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
