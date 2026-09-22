import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/app/widgets/near_send_widgets.dart';
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

/// Where the attempt to reach another device is.
enum ConnectionAttemptPhase { idle, connecting, connected, failed }

/// The connection attempt, as this screen renders it.
///
/// A plain value rather than the session that produced it: a screen that held a live session would
/// need a real socket to render, and the interesting states here - a mismatched fingerprint, a peer
/// that does not answer - are exactly the ones a widget test must be able to state.
class ConnectionAttempt {
  const ConnectionAttempt({
    this.phase = ConnectionAttemptPhase.idle,
    this.reason,
    this.peerFingerprint,
    this.pinMismatched = false,
  });

  final ConnectionAttemptPhase phase;

  /// Why it failed, as a sentence a user can act on.
  final String? reason;

  /// The fingerprint the peer's certificate produced, when one was seen and did not match.
  ///
  /// Shown because it is the only way a person can see that two devices disagree about a
  /// certificate rather than merely that a connection failed. It is not a secret: it is the value
  /// the peer publishes in its own connection information.
  final String? peerFingerprint;

  /// Whether the refusal was a fingerprint mismatch rather than an unreachable peer.
  final bool pinMismatched;

  bool get isBusy => phase == ConnectionAttemptPhase.connecting;
  bool get isConnected => phase == ConnectionAttemptPhase.connected;
  bool get hasFailed => phase == ConnectionAttemptPhase.failed;
}

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({
    super.key,
    required this.payload,
    this.onConnect,
    this.starting = false,
    this.unavailableReason,
    this.connection = const ConnectionAttempt(),
    this.onContinue,
    this.continueLabel = continueLabelSend,
    this.localDeviceName = 'NearSend',
    this.localPlatform = '当前平台',
    this.peerDeviceName = '对端设备名称未提供',
    this.peerPlatform = '对端平台未提供',
  });

  /// The payload this device publishes, or null when it has not opened a session.
  final PairingPayload? payload;

  /// Called with a payload the user pasted, when it parsed.
  ///
  /// Null when this build has nothing to connect with, in which case the connect button is **not
  /// rendered**: a control that cannot act is the placeholder this project's rules forbid, and an
  /// absent control with a stated reason is the honest version.
  final void Function(PairingPayload payload)? onConnect;

  /// Whether this device's own node is still starting.
  final bool starting;

  /// Why this device has no connection information, when it has none for a reason.
  final String? unavailableReason;

  /// The state of the attempt to reach the other device.
  final ConnectionAttempt connection;

  /// Called once the peer has proved its identity, to move on to what the connection is for.
  ///
  /// Null when this build has nowhere to go yet, in which case the button is not rendered - the same
  /// rule the connect button follows.
  final VoidCallback? onContinue;

  /// What the button after a verified connection says.
  ///
  /// It is the caller's, because the same connection leads to opposite actions: `docs/ui/UI_UX_SPEC.md`
  /// §4 gives sending and receiving one first step and different wording, and a single label would be
  /// wrong for one of them.
  final String continueLabel;

  /// Display-only identity labels. The current pairing protocol does not carry remote device
  /// metadata, so missing values remain explicitly unknown rather than being inferred.
  final String localDeviceName;
  final String localPlatform;
  final String peerDeviceName;
  final String peerPlatform;

  static const String pasteHint = '粘贴对方设备显示的连接信息';
  static const String emptySessionNote = '本机尚未开启配对会话，因此还没有可出示的连接信息。';
  static const String startingNote = '正在启动本机节点，稍后这里会显示本机连接信息…';
  static const String noConnectorNote = '本机尚未接入配对能力，无法发起连接。';

  /// Shown while a connection attempt is in flight.
  static const String connectingNote = '正在连接对方设备…';

  /// Shown once the peer proved the identity the payload named (§2).
  static const String connectedNote = '已连接：对方证书指纹与连接信息一致。';
  static const String fingerprintPendingNote = '完成连接前，指纹只表示待验证信息，不代表已信任。';

  /// The action that follows a verified connection.
  static const String continueLabelSend = '选择文件';
  static const String continueLabelReceive = '查看对方提供的文件';

  /// Shown under the published pin, because that pin is not stable across launches.
  ///
  /// The node generates a fresh TLS identity every time it opens, so the fingerprint a peer
  /// recorded last time will not match this time. That is a real limitation of the current build and
  /// the screen has to say so: a person comparing fingerprints with the peer would otherwise see a
  /// change and reasonably suspect the wrong thing. It disappears when identity persistence lands,
  /// and it must disappear **then** rather than being left behind as a stale warning.
  static const String ephemeralIdentityNote =
      '本机身份在每次启动时重新生成，因此这个指纹下次启动会变；配对结果无法跨重启保留。';

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
    final ConnectionAttempt attempt = widget.connection;

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
                // The order is the order of the questions a user has: can this device be connected
                // to at all, and if not, why. "Not started yet" and "could not start" are different
                // answers, and showing the first while the second is true would send them looking
                // for a fault in the other device.
                if (widget.unavailableReason != null)
                  _Notice(
                    text: widget.unavailableReason!,
                    palette: palette,
                    isError: true,
                  )
                else if (payload == null && widget.starting)
                  _Notice(text: ConnectionPage.startingNote, palette: palette)
                else if (payload == null)
                  _Notice(
                    text: ConnectionPage.emptySessionNote,
                    palette: palette,
                  )
                else
                  _PublishedPayload(
                    payload: payload,
                    palette: palette,
                    deviceName: widget.localDeviceName,
                    platform: widget.localPlatform,
                  ),
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
                if (_import.isAccepted && widget.onConnect != null)
                  FilledButton.icon(
                    onPressed: attempt.isBusy
                        ? null
                        : () => widget.onConnect?.call(_import.payload!),
                    icon: const Icon(Icons.link),
                    label: const Text('连接'),
                  )
                else if (_import.isAccepted)
                  _Notice(
                    text: ConnectionPage.noConnectorNote,
                    palette: palette,
                  ),
                if (attempt.isBusy)
                  Padding(
                    padding: const EdgeInsets.only(top: NearSendSpacing.sm),
                    child: _Notice(
                      text: ConnectionPage.connectingNote,
                      palette: palette,
                    ),
                  ),
                if (attempt.isConnected)
                  Padding(
                    padding: const EdgeInsets.only(top: NearSendSpacing.sm),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _Notice(
                          text: ConnectionPage.connectedNote,
                          palette: palette,
                        ),
                        if (widget.onContinue != null) ...<Widget>[
                          const SizedBox(height: NearSendSpacing.sm),
                          FilledButton.icon(
                            onPressed: widget.onContinue,
                            icon: const Icon(Icons.arrow_forward),
                            label: Text(widget.continueLabel),
                          ),
                        ],
                      ],
                    ),
                  ),
                if (attempt.hasFailed)
                  Padding(
                    padding: const EdgeInsets.only(top: NearSendSpacing.sm),
                    child: _Notice(
                      text: _failureText(attempt),
                      palette: palette,
                      isError: true,
                    ),
                  ),
                if (_import.isAccepted) ...<Widget>[
                  const SizedBox(height: NearSendSpacing.md),
                  _PeerPreview(
                    payload: _import.payload!,
                    deviceName: widget.peerDeviceName,
                    platform: widget.peerPlatform,
                    verified: attempt.isConnected,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The failure sentence, with the fingerprint the peer actually presented when there was one.
  ///
  /// The fingerprint is appended rather than replacing the reason: a mismatch and a peer that does
  /// not answer need different actions, and the value itself is what lets a person see that the two
  /// devices disagree about a certificate rather than that something went wrong.
  String _failureText(ConnectionAttempt attempt) {
    final String reason = attempt.reason ?? ConnectionPage.emptySessionNote;
    final String? presented = attempt.peerFingerprint;
    if (!attempt.pinMismatched || presented == null) {
      return reason;
    }
    return '$reason\n对方出示的指纹：$presented';
  }
}

class _PublishedPayload extends StatelessWidget {
  const _PublishedPayload({
    required this.payload,
    required this.palette,
    required this.deviceName,
    required this.platform,
  });

  final PairingPayload payload;
  final NearSendColors palette;
  final String deviceName;
  final String platform;

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
            _Field(label: '设备名', value: deviceName),
            const SizedBox(height: NearSendSpacing.xs),
            _Field(label: '平台', value: platform),
            const SizedBox(height: NearSendSpacing.xs),
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
            const SizedBox(height: NearSendSpacing.sm),
            // Said because it is currently true and a user would otherwise be misled: the node
            // mints a fresh TLS identity every time it opens, so this pin is not the same one the
            // next launch will show. Without this line a person comparing fingerprints across two
            // launches would conclude the peer changed identity, and a pairing they thought they
            // had made would look like it had been tampered with.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.info_outline, color: palette.warning),
                const SizedBox(width: NearSendSpacing.sm),
                Expanded(
                  child: Text(
                    ConnectionPage.ephemeralIdentityNote,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PeerPreview extends StatelessWidget {
  const _PeerPreview({
    required this.payload,
    required this.deviceName,
    required this.platform,
    required this.verified,
  });

  final PairingPayload payload;
  final String deviceName;
  final String platform;
  final bool verified;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(NearSendSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.devices_outlined),
                const SizedBox(width: NearSendSpacing.sm),
                Expanded(
                  child: Text(
                    '对端设备',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                NsStatusBadge(
                  label: verified ? '已验证' : '待验证',
                  tone: verified ? NsStatusTone.success : NsStatusTone.warning,
                ),
              ],
            ),
            const SizedBox(height: NearSendSpacing.sm),
            _Field(label: '设备名', value: deviceName),
            const SizedBox(height: NearSendSpacing.xs),
            _Field(label: '平台', value: platform),
            const SizedBox(height: NearSendSpacing.xs),
            _Field(label: '地址', value: _addresses),
            const SizedBox(height: NearSendSpacing.xs),
            _Field(label: '待核对指纹', value: payload.serverFingerprint),
            if (!verified) ...<Widget>[
              const SizedBox(height: NearSendSpacing.sm),
              const NsInfoBanner(
                title: '请先核对指纹',
                message: ConnectionPage.fingerprintPendingNote,
                tone: NsStatusTone.warning,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String get _addresses => <String>[
    for (final PairingCandidate candidate in payload.candidates)
      '${candidate.host}:${candidate.port}',
  ].join('、');
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
    return NsInfoBanner(
      title: isError ? '连接未完成' : '连接状态',
      message: text,
      tone: isError ? NsStatusTone.error : NsStatusTone.info,
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
