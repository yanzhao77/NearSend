import 'dart:async';

import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/app/widgets/near_send_widgets.dart';
import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/core/storage/task_authorization_repository.dart';
import 'package:nearsend/features/transfer/application/receiving_flow.dart';
import 'package:nearsend/features/transfer/application/server_receiving_flow.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';

/// The receiving screen: who is offering what, where it will go, and how far it has got.
///
/// ## Why this screen polls
///
/// §6 has no push: a receiving device learns that something is waiting by asking
/// `GET /v1/offers`. So this screen asks, on a timer, and says what it is doing - a screen that
/// waited for an event that never comes would look exactly like a screen that is broken. The timer
/// stops when the widget goes away, and it is not restarted once a transfer is in flight: asking
/// about offers while receiving would be noise about a different question.
///
/// ## Why the save location is typed here rather than defaulted
///
/// §6 keeps the receiver's decision and its save location together, and the location is the one part
/// of receiving a person must be able to control. So it is an input on this screen, the accept
/// button stays disabled until it is filled, and nothing is written anywhere the user did not name.
class ReceivePage extends StatefulWidget {
  const ReceivePage({
    super.key,
    required this.phase,
    required this.offers,
    required this.onRefresh,
    required this.onAccept,
    this.progress,
    this.fileName,
    this.fileNumber = 0,
    this.fileCount = 0,
    this.failureReason,
    this.savedPaths = const <String>[],
    this.refreshInterval = const Duration(seconds: 2),
    this.pushOffers = const <ServerOffer>[],
    this.pushPhase = ServerReceivePhase.waiting,
    this.pushSpaceVerdict,
    this.pushSpaceEstimate,
    this.pushFailureReason,
    this.pushSavedPaths = const <String>[],
    this.onCheckPushSpace,
    this.onPickLocation,
    this.onAcceptPush,
  });

  final ReceivePhase phase;

  /// What the peer was offering at the last ask.
  final List<OfferSummary> offers;

  /// Asks the peer again. Called on a timer while nothing is in flight.
  final Future<void> Function() onRefresh;

  /// Answers one offer, writing the files under the location the user typed.
  final Future<bool> Function(OfferSummary offer, String saveLocation) onAccept;

  final TransferProgress? progress;
  final String? fileName;
  final int fileNumber;
  final int fileCount;
  final String? failureReason;
  final List<String> savedPaths;
  final Duration refreshInterval;

  /// What **this** device is being asked to accept, from its own database.
  ///
  /// The other half of the same screen, and a genuinely different situation: here a client proposed
  /// a transfer *to this node*, so there is nothing to ask the peer - the row is already here, and
  /// the only thing missing is the user's answer.
  final List<ServerOffer> pushOffers;
  final ServerReceivePhase pushPhase;

  /// What the space plan said, when one was run for a pushed transfer.
  ///
  /// Shown rather than assumed: `unknown` means nobody measured the volumes, and a screen that drew
  /// it as a pass would be claiming a check that never happened.
  final SpaceVerdict? pushSpaceVerdict;

  /// The measured, per-volume breakdown for the pushed offer.
  final SpaceEstimateSnapshot? pushSpaceEstimate;

  final String? pushFailureReason;
  final List<String> pushSavedPaths;
  final Future<SpaceEstimateSnapshot?> Function(
    ServerOffer offer,
    String saveLocation,
  )?
  onCheckPushSpace;
  final Future<String?> Function()? onPickLocation;
  final Future<bool> Function(ServerOffer offer, String saveLocation)?
  onAcceptPush;

  static const String heading = '接收文件';
  static const String emptyNote = '对方还没有提供文件。保持连接，这里会自动刷新。';
  static const String saveLocationHint = '保存到哪个目录（需要填写）';
  static const String saveLocationRequired = '请先填写保存目录，再接受。';

  /// Shown when the space plan could not measure the volumes, so nobody may read the screen as
  /// having checked them.
  static const String spaceUnknownNote = '未能测量剩余空间，本次没有做空间预检。';

  /// Shown when the plan proved the transfer does not fit; the acceptance is refused, not warned.
  static const String spaceInsufficientNote = '空间不足：按暂存与导出的峰值计算装不下，需要先清理或更换位置。';
  static const String spacePendingNote = '填写保存位置后会先检查暂存、数据库和导出峰值空间。';
  static const String unknownSpaceAcknowledgement = '我知道无法确认可用空间，仍承担传输中可能失败的风险';

  /// Heading for the section about transfers this device was asked to accept.
  static const String pushSectionHeading = '对方正在发给你';

  static String pushPhaseLabel(ServerReceivePhase phase) => switch (phase) {
    ServerReceivePhase.waiting => '等待对方发送',
    ServerReceivePhase.accepting => '正在确认',
    ServerReceivePhase.receiving => '接收中',
    ServerReceivePhase.verifying => '正在校验并保存',
    ServerReceivePhase.saved => '已保存',
    ServerReceivePhase.failed => '未完成',
  };

  static String phaseLabel(ReceivePhase phase) => switch (phase) {
    ReceivePhase.idle => '等待对方提供',
    ReceivePhase.offered => '对方提供了文件，等待你确认',
    ReceivePhase.accepting => '正在确认并取得凭据',
    ReceivePhase.receiving => '接收中',
    ReceivePhase.saved => '已保存',
    ReceivePhase.failed => '未完成',
  };

  @override
  State<ReceivePage> createState() => _ReceivePageState();
}

class _ReceivePageState extends State<ReceivePage> {
  final TextEditingController _location = TextEditingController();
  Timer? _poll;
  final Map<String, SpaceEstimateSnapshot?> _checkedSpaces =
      <String, SpaceEstimateSnapshot?>{};
  final Map<String, String> _spaceCheckFailures = <String, String>{};
  bool _unknownSpaceAcknowledged = false;

  @override
  void initState() {
    super.initState();
    _startPolling();
  }

  @override
  void didUpdateWidget(ReceivePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pushOffers != widget.pushOffers ||
        oldWidget.pushSpaceEstimate != widget.pushSpaceEstimate) {
      _checkedSpaces.clear();
      if (widget.pushOffers.length == 1 && widget.pushSpaceEstimate != null) {
        _checkedSpaces[widget.pushOffers.single.transferId] =
            widget.pushSpaceEstimate;
      }
      _spaceCheckFailures.clear();
      _unknownSpaceAcknowledged = false;
    }
    if (oldWidget.phase != widget.phase ||
        oldWidget.pushPhase != widget.pushPhase) {
      _startPolling();
    }
  }

  Future<void> _checkPushSpace(ServerOffer offer, String location) async {
    final Future<SpaceEstimateSnapshot?> Function(ServerOffer, String)? check =
        widget.onCheckPushSpace;
    if (check == null || location.trim().isEmpty) {
      return;
    }
    setState(() => _spaceCheckFailures.remove(offer.transferId));
    try {
      final SpaceEstimateSnapshot? result = await check(offer, location.trim());
      if (!mounted) return;
      setState(() {
        _checkedSpaces[offer.transferId] = result;
        _unknownSpaceAcknowledged = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _checkedSpaces.remove(offer.transferId);
        _spaceCheckFailures[offer.transferId] = '空间预检未完成，请重试或更换保存位置。';
      });
    }
  }

  void _onLocationChanged(String value) {
    setState(() {
      _unknownSpaceAcknowledged = false;
      _checkedSpaces.clear();
      _spaceCheckFailures.clear();
    });
    if (value.trim().isNotEmpty) {
      for (final ServerOffer offer in widget.pushOffers) {
        unawaited(_checkPushSpace(offer, value));
      }
    }
  }

  Future<void> _pickLocation() async {
    final String? picked = await widget.onPickLocation?.call();
    if (!mounted || picked == null || picked.trim().isEmpty) return;
    _location
      ..text = picked
      ..selection = TextSelection.collapsed(offset: picked.length);
    _onLocationChanged(picked);
  }

  @override
  void dispose() {
    _poll?.cancel();
    _location.dispose();
    super.dispose();
  }

  /// Asks once now, then on a timer while there is nothing in flight.
  ///
  /// Both halves are asked: a client's view of what the peer offers, and this device's own view of
  /// what a client is pushing to it. Either can arrive while the user is sitting here, and §6 has no
  /// push to announce either of them.
  void _startPolling() {
    _poll?.cancel();
    final bool waitingForOffer =
        widget.phase == ReceivePhase.idle ||
        widget.phase == ReceivePhase.offered;
    final bool waitingForPush = widget.pushPhase == ServerReceivePhase.waiting;
    if (!waitingForOffer && !waitingForPush) {
      return;
    }
    unawaited(widget.onRefresh());
    _poll = Timer.periodic(widget.refreshInterval, (Timer _) {
      unawaited(widget.onRefresh());
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool canAccept =
        !_isBusy &&
        widget.offers.isNotEmpty &&
        _location.text.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text(ReceivePage.heading)),
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
                  ReceivePage.phaseLabel(widget.phase),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: NearSendSpacing.md),
                // Only while an offer could still arrive. After a failure, 对方还没有提供文件 is a
                // different and false statement: it invites the user to keep waiting for something
                // this screen has stopped asking about.
                if (widget.offers.isEmpty &&
                    (widget.phase == ReceivePhase.idle ||
                        widget.phase == ReceivePhase.offered))
                  const NsInfoBanner(
                    title: '等待文件',
                    message: ReceivePage.emptyNote,
                    tone: NsStatusTone.info,
                  ),
                for (final OfferSummary offer in widget.offers) ...<Widget>[
                  NsFileRow(
                    fileName: '来自对方的文件',
                    sizeLabel: formatBytes(offer.totalBytes),
                    statusLabel: '${offer.fileCount} 个文件 · 待确认',
                    statusTone: NsStatusTone.warning,
                    icon: Icons.download_outlined,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: NearSendSpacing.xs),
                    child: Text(
                      '${offer.fileCount} 个文件 · ${formatBytes(offer.totalBytes)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(height: NearSendSpacing.sm),
                ],
                const SizedBox(height: NearSendSpacing.sm),
                TextField(
                  controller: _location,
                  enabled: !_isBusy,
                  onChanged: _onLocationChanged,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: ReceivePage.saveLocationHint,
                  ),
                ),
                if (widget.onPickLocation != null) ...<Widget>[
                  const SizedBox(height: NearSendSpacing.sm),
                  NsSecondaryButton(
                    onPressed: _isBusy ? null : _pickLocation,
                    icon: Icons.folder_open,
                    label: '选择保存位置',
                  ),
                ],
                if (widget.offers.isNotEmpty && _location.text.trim().isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: NearSendSpacing.xs),
                    child: NsInfoBanner(
                      title: '需要保存位置',
                      message: ReceivePage.saveLocationRequired,
                      tone: NsStatusTone.warning,
                    ),
                  ),
                const SizedBox(height: NearSendSpacing.sm),
                for (final OfferSummary offer in widget.offers)
                  Padding(
                    padding: const EdgeInsets.only(bottom: NearSendSpacing.sm),
                    child: FilledButton.icon(
                      onPressed: canAccept
                          ? () => unawaited(
                              widget.onAccept(offer, _location.text.trim()),
                            )
                          : null,
                      icon: const Icon(Icons.check),
                      label: const Text('接收并保存'),
                    ),
                  ),
                if (widget.onAcceptPush != null) ...<Widget>[
                  const Divider(height: NearSendSpacing.xl),
                  Text(
                    ReceivePage.pushSectionHeading,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: NearSendSpacing.sm),
                  Text(
                    ReceivePage.pushPhaseLabel(widget.pushPhase),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  for (final ServerOffer offer
                      in widget.pushOffers) ...<Widget>[
                    const SizedBox(height: NearSendSpacing.sm),
                    NsFileRow(
                      fileName: '来自对方的文件',
                      sizeLabel: formatBytes(offer.totalBytes),
                      statusLabel: '${offer.fileCount} 个文件 · 待确认',
                      statusTone: NsStatusTone.warning,
                      icon: Icons.move_to_inbox_outlined,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: NearSendSpacing.xs),
                      child: Text(
                        '${offer.fileCount} 个文件 · ${formatBytes(offer.totalBytes)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    ..._spaceWidgets(context, offer),
                    if (canAcceptPush(offer))
                      Padding(
                        padding: const EdgeInsets.only(top: NearSendSpacing.sm),
                        child: NsPrimaryButton(
                          onPressed: () => unawaited(
                            widget.onAcceptPush!(offer, _location.text.trim()),
                          ),
                          icon: Icons.check,
                          label: '接收并保存',
                        ),
                      ),
                  ],
                  if (widget.pushOffers.isNotEmpty &&
                      _location.text.trim().isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: NearSendSpacing.xs),
                      child: NsInfoBanner(
                        title: '需要保存位置',
                        message: ReceivePage.saveLocationRequired,
                        tone: NsStatusTone.warning,
                      ),
                    ),
                  for (final String path in widget.pushSavedPaths)
                    Padding(
                      padding: const EdgeInsets.only(top: NearSendSpacing.sm),
                      child: NsInfoBanner(
                        title: '已保存',
                        message: '已保存：$path',
                        tone: NsStatusTone.success,
                      ),
                    ),
                  if (widget.pushFailureReason != null)
                    Padding(
                      padding: const EdgeInsets.only(top: NearSendSpacing.sm),
                      child: NsInfoBanner(
                        title: '接收未完成',
                        message: widget.pushFailureReason!,
                        tone: NsStatusTone.error,
                      ),
                    ),
                ],
                _PhaseSection(
                  phase: widget.phase,
                  progress: widget.progress,
                  fileName: widget.fileName,
                  fileNumber: widget.fileNumber,
                  fileCount: widget.fileCount,
                  failureReason: widget.failureReason,
                  savedPaths: widget.savedPaths,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool get _isBusy =>
      widget.phase == ReceivePhase.accepting ||
      widget.phase == ReceivePhase.receiving;

  /// Whether one pushed offer can be answered now: a location, and nothing already in flight.
  bool canAcceptPush(ServerOffer offer) =>
      widget.onAcceptPush != null &&
      !_isPushing &&
      _location.text.trim().isNotEmpty &&
      _effectiveVerdict(offer) != SpaceVerdict.insufficient &&
      _effectiveVerdict(offer) != null &&
      (_effectiveVerdict(offer) != SpaceVerdict.unknown ||
          _unknownSpaceAcknowledged);

  SpaceEstimateSnapshot? _effectiveSpace(ServerOffer offer) =>
      _checkedSpaces[offer.transferId] ??
      (widget.pushOffers.length == 1 &&
              offer.transferId == widget.pushOffers.single.transferId
          ? widget.pushSpaceEstimate
          : null);

  SpaceVerdict? _effectiveVerdict(ServerOffer offer) =>
      _effectiveSpace(offer)?.verdict ??
      (widget.pushOffers.length == 1 &&
              offer.transferId == widget.pushOffers.single.transferId
          ? widget.pushSpaceVerdict
          : null);

  List<Widget> _spaceWidgets(BuildContext context, ServerOffer offer) {
    final SpaceEstimateSnapshot? estimate = _effectiveSpace(offer);
    final SpaceVerdict? verdict = _effectiveVerdict(offer);
    final String? checkFailure = _spaceCheckFailures[offer.transferId];
    if (checkFailure != null) {
      return <Widget>[
        const SizedBox(height: NearSendSpacing.sm),
        NsInfoBanner(
          title: '空间预检失败',
          message: checkFailure,
          tone: NsStatusTone.error,
        ),
      ];
    }
    if (estimate == null) {
      if (verdict == SpaceVerdict.insufficient) {
        return <Widget>[
          const SizedBox(height: NearSendSpacing.sm),
          const NsInfoBanner(
            title: '空间不足',
            message: ReceivePage.spaceInsufficientNote,
            tone: NsStatusTone.error,
          ),
        ];
      }
      if (verdict == SpaceVerdict.unknown) {
        return <Widget>[
          const SizedBox(height: NearSendSpacing.sm),
          const NsInfoBanner(
            title: '空间未知',
            message: ReceivePage.spaceUnknownNote,
            tone: NsStatusTone.warning,
          ),
          CheckboxListTile(
            value: _unknownSpaceAcknowledged,
            onChanged: (bool? value) =>
                setState(() => _unknownSpaceAcknowledged = value ?? false),
            title: const Text(ReceivePage.unknownSpaceAcknowledgement),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
        ];
      }
      return <Widget>[
        const SizedBox(height: NearSendSpacing.sm),
        NsInfoBanner(
          title: '空间预检待完成',
          message: ReceivePage.spacePendingNote,
          tone: NsStatusTone.warning,
        ),
      ];
    }
    final List<Widget> widgets = <Widget>[
      const SizedBox(height: NearSendSpacing.sm),
      for (final SpaceVolumeSnapshot volume in estimate.volumes)
        Padding(
          padding: const EdgeInsets.only(bottom: NearSendSpacing.sm),
          child: NsSpaceBreakdown(
            title: volume.volumeRef,
            status: _spaceStatus(volume.verdict),
            statusLabel: _spaceStatusLabel(volume),
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
                NsSpaceLine(label: line.reason, value: formatBytes(line.bytes)),
            ],
            shortfallLabel: volume.shortfallBytes == null
                ? null
                : '还差 ${formatBytes(volume.shortfallBytes!)}',
          ),
        ),
    ];
    if (estimate.verdict == SpaceVerdict.unknown) {
      widgets.add(
        CheckboxListTile(
          value: _unknownSpaceAcknowledged,
          onChanged: (bool? value) =>
              setState(() => _unknownSpaceAcknowledged = value ?? false),
          title: const Text(ReceivePage.unknownSpaceAcknowledgement),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
        ),
      );
    }
    if (estimate.verdict == SpaceVerdict.insufficient) {
      widgets.add(
        const NsInfoBanner(
          title: '空间不足',
          message: ReceivePage.spaceInsufficientNote,
          tone: NsStatusTone.error,
        ),
      );
    }
    if (estimate.verdict == SpaceVerdict.unknown) {
      widgets.add(
        const NsInfoBanner(
          title: '空间未知',
          message: ReceivePage.spaceUnknownNote,
          tone: NsStatusTone.warning,
        ),
      );
    }
    return widgets;
  }

  static NsSpaceStatus _spaceStatus(SpaceVerdict verdict) => switch (verdict) {
    SpaceVerdict.sufficient => NsSpaceStatus.sufficient,
    SpaceVerdict.insufficient => NsSpaceStatus.insufficient,
    SpaceVerdict.unknown => NsSpaceStatus.unknown,
  };

  static String _spaceStatusLabel(SpaceVolumeSnapshot volume) =>
      switch (volume.verdict) {
        SpaceVerdict.sufficient => '空间充足',
        SpaceVerdict.insufficient => '空间不足',
        SpaceVerdict.unknown => '无法确认',
      };

  bool get _isPushing =>
      widget.pushPhase == ServerReceivePhase.accepting ||
      widget.pushPhase == ServerReceivePhase.receiving ||
      widget.pushPhase == ServerReceivePhase.verifying;

  @override
  void reassemble() {
    super.reassemble();
    _startPolling();
  }
}

class _PhaseSection extends StatelessWidget {
  const _PhaseSection({
    required this.phase,
    required this.progress,
    required this.fileName,
    required this.fileNumber,
    required this.fileCount,
    required this.failureReason,
    required this.savedPaths,
  });

  final ReceivePhase phase;
  final TransferProgress? progress;
  final String? fileName;
  final int fileNumber;
  final int fileCount;
  final String? failureReason;
  final List<String> savedPaths;

  @override
  Widget build(BuildContext context) {
    final TransferProgress? figures = progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (fileCount > 1 && fileNumber > 0)
          Text(
            '第 $fileNumber / $fileCount 个文件',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (figures != null) ...<Widget>[
          const SizedBox(height: NearSendSpacing.sm),
          Text(fileName ?? '', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: NearSendSpacing.xs),
          if (figures.fraction != null)
            LinearProgressIndicator(value: figures.fraction)
          else
            const LinearProgressIndicator(),
          const SizedBox(height: NearSendSpacing.sm),
          _Stat(label: '已收 / 总量', value: figures.byteLabel),
          _Stat(label: '速度', value: figures.speedLabel),
          _Stat(label: '剩余时间', value: figures.remainingLabel),
        ],
        for (final String path in savedPaths)
          Padding(
            padding: const EdgeInsets.only(top: NearSendSpacing.sm),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(NearSendSpacing.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const SizedBox(width: NearSendSpacing.sm),
                    Expanded(child: Text('已保存：$path')),
                  ],
                ),
              ),
            ),
          ),
        if (failureReason != null)
          Padding(
            padding: const EdgeInsets.only(top: NearSendSpacing.sm),
            child: NsInfoBanner(
              title: '接收未完成',
              message: failureReason!,
              tone: NsStatusTone.error,
            ),
          ),
      ],
    );
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
