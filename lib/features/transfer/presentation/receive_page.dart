import 'dart:async';

import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/features/transfer/application/receiving_flow.dart';
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

  static const String heading = '接收文件';
  static const String emptyNote = '对方还没有提供文件。保持连接，这里会自动刷新。';
  static const String saveLocationHint = '保存到哪个目录（需要填写）';
  static const String saveLocationRequired = '请先填写保存目录，再接受。';

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
    if (oldWidget.phase != widget.phase) {
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
  void _startPolling() {
    _poll?.cancel();
    if (widget.phase == ReceivePhase.idle ||
        widget.phase == ReceivePhase.offered) {
      unawaited(widget.onRefresh());
      _poll = Timer.periodic(
        widget.refreshInterval,
        (Timer _) => unawaited(widget.onRefresh()),
      );
    }
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
