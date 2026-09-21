import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';

/// The connection screen: what this device publishes, and how to reach another one.
///
/// `docs/ui/UI_UX_SPEC.md` §5 splits the connection step by role, and this page is the side the
/// user sees when *this* device is the one being connected to:
///
/// * the pin, which §2 makes the whole of the trust decision, shown as text a person can compare
///   out loud;
/// * the candidate addresses §3 puts in the payload;
/// * a place to paste a payload the other device is showing, so a device without a working camera
///   is not locked out.
///
/// Nothing on this page is a placeholder. The payload it renders comes from a real
/// `PairingService` session, and pasting one runs the **same strict parser** a scanner would, so a
/// payload that this page accepts is one the pairing handshake will accept. A payload it refuses
/// is refused with the parser's own reason rather than by a looser check here.
///
/// ## What it deliberately does not do
///
/// It does not draw a QR image. Rendering one needs a QR encoder, and `AGENTS.md` §3 makes adding
/// a dependency a decision to be justified rather than assumed; until that decision is taken, the
/// payload is shown as text and copying it is the documented path. The page says so rather than
/// showing an empty box where a code should be.

/// The state of the "paste a payload" field.
class PairingImportState {
  const PairingImportState({this.payload, this.error});

  /// The parsed payload, when the text is one.
  final PairingPayload? payload;

  /// Why it was refused, when it was. The parser's own message, not a generic one.
  final String? error;

  bool get isAccepted => payload != null;
}

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({super.key, required this.payload, this.onConnect});

  /// The payload this device publishes, or null when it has not opened a session.
  final PairingPayload? payload;

  /// Called with a payload the user pasted, when it parsed.
  final void Function(PairingPayload payload)? onConnect;

  static const String pasteHint = '粘贴对方设备显示的连接信息';
  static const String emptySessionNote = '本机尚未开启配对会话，因此还没有可出示的连接信息。';

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  final TextEditingController _controller = TextEditingController();
  PairingImportState _import = const PairingImportState();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _parse(String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      setState(() => _import = const PairingImportState());
      return;
    }
    try {
      // The scanner's parser, so this page cannot accept something the handshake would refuse.
      final PairingPayload parsed = PairingPayload.parse(trimmed);
      setState(() => _import = PairingImportState(payload: parsed));
    } on Object catch (error) {
      setState(() => _import = PairingImportState(error: '$error'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final NearSendColors palette = NearSendColors.of(
      Theme.of(context).brightness,
    );
    final PairingPayload? payload = widget.payload;

    return Scaffold(
      appBar: AppBar(title: const Text('连接信息')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: NearSendSizing.formMaxWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.all(NearSendSpacing.lg),
              children: <Widget>[
                if (payload == null)
                  _Notice(
                    text: ConnectionPage.emptySessionNote,
                    palette: palette,
                  )
                else
                  _PublishedPayload(payload: payload, palette: palette),
                const SizedBox(height: NearSendSpacing.xl),
                Text(
                  ConnectionPage.pasteHint,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: NearSendSpacing.sm),
                TextField(
                  controller: _controller,
                  onChanged: _parse,
                  maxLines: 4,
                  minLines: 3,
                  autofocus: false,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: '{"kind":"lft-pair", …}',
                  ),
                ),
                const SizedBox(height: NearSendSpacing.sm),
                if (_import.error != null)
                  _Notice(
                    text: _import.error!,
                    palette: palette,
                    isError: true,
                  ),
                if (_import.isAccepted)
                  FilledButton.icon(
                    onPressed: () => widget.onConnect?.call(_import.payload!),
                    icon: const Icon(Icons.link),
                    label: const Text('连接'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PublishedPayload extends StatelessWidget {
  const _PublishedPayload({required this.payload, required this.palette});

  final PairingPayload payload;
  final NearSendColors palette;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(NearSendSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('本机连接信息', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: NearSendSpacing.sm),
            _Field(label: '证书指纹（pin）', value: payload.serverFingerprint),
            const SizedBox(height: NearSendSpacing.xs),
            _Field(
              label: '可连接地址',
              value: <String>[
                for (final PairingCandidate candidate in payload.candidates)
                  '${candidate.host}:${candidate.port}',
              ].join('、'),
            ),
            const SizedBox(height: NearSendSpacing.xs),
            _Field(label: '会话', value: payload.sessionId),
            const SizedBox(height: NearSendSpacing.sm),
            Text(
              '请让对方核对上面的指纹后再连接。指纹不符时应重新配对，而不是继续。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        SelectableText(value, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.text,
    required this.palette,
    this.isError = false,
  });

  final String text;
  final NearSendColors palette;
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

/// The transfer screen: real figures, and the controls that act on them.
///
/// `docs/ui/UI_UX_SPEC.md` §5 requires the transferred and total bytes, the speed, the remaining
/// time, and pause/resume/cancel. Every number comes from [TransferProgress], whose source is the
/// receiver's committed rows - so a bar here cannot show progress that a crash would take back.
///
/// The controls are **absent rather than disabled** when the phase does not allow them: a greyed
/// pause button on a completed transfer invites the user to wonder why, and §5's accessibility
/// requirement is easier to meet with fewer focus stops that mean nothing.
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
