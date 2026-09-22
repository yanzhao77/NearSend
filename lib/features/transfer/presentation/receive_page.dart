import 'dart:async';

import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/storage/space_plan.dart';
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
    this.pushFailureReason,
    this.pushSavedPaths = const <String>[],
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

  final String? pushFailureReason;
  final List<String> pushSavedPaths;
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

  @override
  void initState() {
    super.initState();
    _startPolling();
  }

  @override
  void didUpdateWidget(ReceivePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phase != widget.phase ||
        oldWidget.pushPhase != widget.pushPhase) {
      _startPolling();
    }
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
    final NearSendColors palette = NearSendColors.of(
      Theme.of(context).brightness,
    );
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
                  _Notice(palette: palette, text: ReceivePage.emptyNote),
                for (final OfferSummary offer in widget.offers) ...<Widget>[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(NearSendSpacing.md),
                      child: Row(
                        children: <Widget>[
                          const Icon(Icons.download_outlined),
                          const SizedBox(width: NearSendSpacing.sm),
                          Expanded(
                            child: Text(
                              '${offer.fileCount} 个文件 · '
                              '${formatBytes(offer.totalBytes)}',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: NearSendSpacing.sm),
                ],
                const SizedBox(height: NearSendSpacing.sm),
                TextField(
                  controller: _location,
                  enabled: !_isBusy,
                  onChanged: (String _) => setState(() {}),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: ReceivePage.saveLocationHint,
                  ),
                ),
                if (widget.offers.isNotEmpty && _location.text.trim().isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: NearSendSpacing.xs),
                    child: Text(
                      ReceivePage.saveLocationRequired,
                      style: Theme.of(context).textTheme.bodySmall,
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
                      label: const Text('接受并接收'),
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
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(NearSendSpacing.md),
                        child: Row(
                          children: <Widget>[
                            const Icon(Icons.move_to_inbox_outlined),
                            const SizedBox(width: NearSendSpacing.sm),
                            Expanded(
                              child: Text(
                                '${offer.fileCount} 个文件 · '
                                '${formatBytes(offer.totalBytes)}',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (canAcceptPush(offer))
                      Padding(
                        padding: const EdgeInsets.only(top: NearSendSpacing.sm),
                        child: FilledButton.icon(
                          onPressed: () => unawaited(
                            widget.onAcceptPush!(offer, _location.text.trim()),
                          ),
                          icon: const Icon(Icons.check),
                          label: const Text('接受这次发送'),
                        ),
                      ),
                  ],
                  if (widget.pushOffers.isNotEmpty &&
                      _location.text.trim().isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: NearSendSpacing.xs),
                      child: Text(
                        ReceivePage.saveLocationRequired,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  // The space answer, said as what it is. `unknown` is the one that matters most:
                  // this build has no way to measure a volume, and a screen that stayed silent about
                  // that would let the user believe the space was checked.
                  if (widget.pushSpaceVerdict == SpaceVerdict.unknown)
                    Padding(
                      padding: const EdgeInsets.only(top: NearSendSpacing.sm),
                      child: _Notice(
                        palette: palette,
                        text: ReceivePage.spaceUnknownNote,
                      ),
                    ),
                  if (widget.pushSpaceVerdict == SpaceVerdict.insufficient)
                    Padding(
                      padding: const EdgeInsets.only(top: NearSendSpacing.sm),
                      child: _Notice(
                        palette: palette,
                        text: ReceivePage.spaceInsufficientNote,
                        isError: true,
                      ),
                    ),
                  for (final String path in widget.pushSavedPaths)
                    Padding(
                      padding: const EdgeInsets.only(top: NearSendSpacing.sm),
                      child: _Notice(palette: palette, text: '已保存：$path'),
                    ),
                  if (widget.pushFailureReason != null)
                    Padding(
                      padding: const EdgeInsets.only(top: NearSendSpacing.sm),
                      child: _Notice(
                        palette: palette,
                        text: widget.pushFailureReason!,
                        isError: true,
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
                  palette: palette,
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
      _location.text.trim().isNotEmpty;

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
    required this.palette,
  });

  final ReceivePhase phase;
  final TransferProgress? progress;
  final String? fileName;
  final int fileNumber;
  final int fileCount;
  final String? failureReason;
  final List<String> savedPaths;
  final NearSendColors palette;

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
                    Icon(Icons.check_circle_outline, color: palette.primary),
                    const SizedBox(width: NearSendSpacing.sm),
                    Expanded(
                      child: Text(
                        '已保存：$path',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (failureReason != null)
          Padding(
            padding: const EdgeInsets.only(top: NearSendSpacing.sm),
            child: _Notice(
              palette: palette,
              text: failureReason!,
              isError: true,
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

class _Notice extends StatelessWidget {
  const _Notice({
    required this.palette,
    required this.text,
    this.isError = false,
  });

  final NearSendColors palette;
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(NearSendSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              isError ? Icons.error_outline : Icons.info_outline,
              color: isError ? palette.error : palette.primary,
            ),
            const SizedBox(width: NearSendSpacing.sm),
            Expanded(
              child: Text(text, style: Theme.of(context).textTheme.bodySmall),
            ),
          ],
        ),
      ),
    );
  }
}
