import 'dart:async';

import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/app/widgets/near_send_widgets.dart';
import 'package:nearsend/core/security/bootstrap_pairing_payload.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/features/pairing/presentation/pairing_qr_widgets.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';
import 'package:nearsend/platform/platform_permission_gateway.dart';
import 'package:nearsend/platform/qr_image_gateway.dart';

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
  const PairingImportState({this.payload, this.bootstrap, this.error});

  /// The parsed payload, when the text is one.
  final PairingPayload? payload;
  final BootstrapPairingPayload? bootstrap;

  /// Why it was refused, when it was. The parser's own message, not a generic one.
  final String? error;

  bool get isAccepted => pairing != null;

  PairingPayload? get pairing => bootstrap?.pairing ?? payload;
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
    this.onConnectBootstrap,
    this.enableCameraScanner = false,
    this.qrImageGateway,
    this.permissionGateway = const MethodChannelPlatformPermissionGateway(),
    this.cameraScannerPageBuilder,
    this.startWithCamera = false,
    this.connectImmediately = false,
    this.starting = false,
    this.unavailableReason,
    this.connection = const ConnectionAttempt(),
    this.onContinue,
    this.continueLabel = continueLabelSend,
    this.localDeviceName = 'NearSend',
    this.localPlatform = '当前平台',
    this.peerDeviceName = '对端设备名称未提供',
    this.peerPlatform = '对端平台未提供',
    this.selectedPeerName,
    this.selectedPeerPlatform,
    this.selectedPeerDiscoveryMethod,
    this.selectedPeerDetail,
    this.selectedPeerConnectionDetail,
    this.selectedPeerReady = false,
    this.persistentLocalIdentity = false,
  });

  /// The payload this device publishes, or null when it has not opened a session.
  final PairingPayload? payload;

  /// Called with a payload the user pasted, when it parsed.
  ///
  /// Null when this build has nothing to connect with, in which case the connect button is **not
  /// rendered**: a control that cannot act is the placeholder this project's rules forbid, and an
  /// absent control with a stated reason is the honest version.
  final void Function(PairingPayload payload)? onConnect;
  final void Function(BootstrapPairingPayload payload)? onConnectBootstrap;
  final bool enableCameraScanner;
  final QrImageGateway? qrImageGateway;
  final PlatformPermissionGateway permissionGateway;
  final WidgetBuilder? cameraScannerPageBuilder;
  final bool startWithCamera;

  /// Automatically starts the connection once a valid scanned or pasted payload is available.
  ///
  /// This does not weaken TLS pinning: [PeerSession] still refuses to submit the one-time token
  /// unless the presented certificate matches the fingerprint in the payload.
  final bool connectImmediately;

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
  final String? selectedPeerName;
  final String? selectedPeerPlatform;
  final String? selectedPeerDiscoveryMethod;
  final String? selectedPeerDetail;
  final String? selectedPeerConnectionDetail;
  final bool selectedPeerReady;
  final bool persistentLocalIdentity;

  static const String pasteHint = '粘贴对方设备显示的连接信息';
  static const String emptySessionNote = '本机尚未开启配对会话，因此还没有可出示的连接信息。';
  static const String startingNote = '正在启动本机节点，稍后这里会显示本机连接信息…';
  static const String noConnectorNote = '本机尚未接入配对能力，无法发起连接。';

  /// Shown while a connection attempt is in flight.
  static const String connectingNote = '正在连接对方设备…';

  /// Shown once the peer proved the identity the payload named (§2).
  static const String connectedNote = '已连接：系统已自动校验对方证书指纹。';
  static const String fingerprintPendingNote = '连接时会自动校验证书指纹；不匹配会立即阻断连接。';

  /// The action that follows a verified connection.
  static const String continueLabelSend = '选择文件';
  static const String continueLabelReceive = '查看对方提供的文件';

  /// Shown only when the current platform is using the explicit ephemeral identity provider.
  static const String ephemeralIdentityNote =
      '本机身份在每次启动时重新生成，因此这个指纹下次启动会变；配对结果无法跨重启保留。';

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  final TextEditingController _controller = TextEditingController();
  PairingImportState _import = const PairingImportState();
  bool _checkingCameraPermission = false;
  String? _cameraPermissionError;
  bool _autoConnectScheduled = false;

  @override
  void didUpdateWidget(covariant ConnectionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.startWithCamera ||
        oldWidget.connection.phase != ConnectionAttemptPhase.connecting ||
        !widget.connection.hasFailed) {
      return;
    }
    final String reason = widget.connection.reason ?? '连接对方设备失败，请检查对方状态后重试。';
    final String? fingerprint = widget.connection.pinMismatched
        ? widget.connection.peerFingerprint
        : null;
    final String message = fingerprint == null
        ? reason
        : '$reason\n检测到的证书指纹：$fingerprint';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reportScanFailure(message);
    });
  }

  @override
  void initState() {
    super.initState();
    if (widget.startWithCamera) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_scan());
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _parse(String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      _autoConnectScheduled = false;
      setState(() => _import = const PairingImportState());
      return;
    }
    late final PairingImportState next;
    try {
      final ScannedPairingPayload parsed = ScannedPairingPayload.parse(trimmed);
      next = switch (parsed) {
        LegacyScannedPairingPayload() => PairingImportState(
          payload: parsed.pairing,
        ),
        BootstrapPairingPayload() => PairingImportState(bootstrap: parsed),
      };
    } on Object catch (error) {
      _autoConnectScheduled = false;
      next = PairingImportState(error: '$error');
    }
    setState(() => _import = next);
    if (widget.connectImmediately &&
        next.isAccepted &&
        !_autoConnectScheduled) {
      _autoConnectScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.connection.isBusy) _connectImported();
      });
    }
  }

  void _acceptImportedText(String value) {
    _controller.text = value;
    _parse(value);
  }

  Future<void> _scan() async {
    if (_checkingCameraPermission) return;
    setState(() {
      _checkingCameraPermission = true;
      _cameraPermissionError = null;
    });
    try {
      final PlatformPermissionState permission =
          await _checkAndRequestCameraPermission();
      if (!mounted) return;
      if (permission != PlatformPermissionState.granted) {
        final String message = permission == PlatformPermissionState.denied
            ? '相机权限未获批准，请在系统设置中允许 NearSend 使用相机后重试。'
            : '系统未能确认相机权限状态，请检查系统相机权限设置后重试。';
        _reportScanFailure(message);
        return;
      }
      final Object? result = await Navigator.of(context).push<Object?>(
        MaterialPageRoute<Object?>(
          builder:
              widget.cameraScannerPageBuilder ??
              (_) => const MobilePairingScannerPage(),
        ),
      );
      if (!mounted) return;
      if (result is String) {
        _acceptImportedText(result);
      } else if (result is PairingScanFailure) {
        _reportScanFailure(result.message);
      } else if (widget.startWithCamera) {
        // A user-cancelled scanner returns quietly to the home page.
        Navigator.of(context).pop<Object?>();
      }
    } on Object catch (error) {
      if (mounted) {
        _reportScanFailure('检查或申请相机权限失败：$error');
      }
    } finally {
      if (mounted && !widget.startWithCamera) {
        setState(() => _checkingCameraPermission = false);
      }
    }
  }

  void _reportScanFailure(String message) {
    if (widget.startWithCamera) {
      Navigator.of(context).pop<Object?>(PairingScanFailure(message));
    } else {
      setState(() => _cameraPermissionError = message);
    }
  }

  Future<PlatformPermissionState> _checkAndRequestCameraPermission() async {
    final PlatformPermissionState current = await widget.permissionGateway
        .check(PlatformPermissionKind.camera);
    if (current == PlatformPermissionState.granted) return current;

    final PlatformPermissionState requested = await widget.permissionGateway
        .request(PlatformPermissionKind.camera);
    if (requested != PlatformPermissionState.granted) return requested;

    // Re-read the native state after the user responds. A successful request
    // callback alone is not enough to start the camera if the OS grant changed
    // while the scanner route was being opened.
    return widget.permissionGateway.check(PlatformPermissionKind.camera);
  }

  void _connectImported() {
    final BootstrapPairingPayload? bootstrap = _import.bootstrap;
    if (bootstrap != null) {
      widget.onConnectBootstrap?.call(bootstrap);
    } else {
      widget.onConnect?.call(_import.payload!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final NearSendColors palette = NearSendColors.of(
      Theme.of(context).brightness,
    );
    final PairingPayload? payload = widget.payload;
    final ConnectionAttempt attempt = widget.connection;
    final bool canConnectImported =
        (_import.bootstrap == null && widget.onConnect != null) ||
        (_import.bootstrap != null && widget.onConnectBootstrap != null);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.selectedPeerName == null ? '连接信息' : '对方连接信息'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: NearSendSizing.formMaxWidth,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(NearSendSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // The order is the order of the questions a user has: can this device be connected
                  // to at all, and if not, why. "Not started yet" and "could not start" are different
                  // answers, and showing the first while the second is true would send them looking
                  // for a fault in the other device.
                  if (widget.selectedPeerName != null)
                    _DiscoveredPeerPreview(
                      name: widget.selectedPeerName!,
                      platform: widget.selectedPeerPlatform ?? '平台未知',
                      discoveryMethod:
                          widget.selectedPeerDiscoveryMethod ?? '发现方式未知',
                      detail: widget.selectedPeerDetail ?? '等待连接',
                      connectionDetail: widget.selectedPeerConnectionDetail,
                      verifiedReady: widget.selectedPeerReady,
                    )
                  else if (widget.unavailableReason != null)
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
                      persistentIdentity: widget.persistentLocalIdentity,
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
                  if (widget.enableCameraScanner ||
                      widget.qrImageGateway != null)
                    Wrap(
                      spacing: NearSendSpacing.sm,
                      runSpacing: NearSendSpacing.sm,
                      children: <Widget>[
                        if (widget.enableCameraScanner)
                          OutlinedButton.icon(
                            onPressed: _checkingCameraPermission ? null : _scan,
                            icon: _checkingCameraPermission
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.qr_code_scanner),
                            label: Text(
                              _checkingCameraPermission ? '正在检查权限' : '扫描二维码',
                            ),
                          ),
                        if (widget.qrImageGateway != null)
                          SizedBox(
                            width: 180,
                            child: PairingImageImportButton(
                              gateway: widget.qrImageGateway!,
                              onDecoded: _acceptImportedText,
                              permissionGateway: widget.permissionGateway,
                            ),
                          ),
                      ],
                    ),
                  if (_cameraPermissionError != null) ...<Widget>[
                    const SizedBox(height: NearSendSpacing.sm),
                    NsPermissionExplainer(
                      title: '需要摄像头权限',
                      message: _cameraPermissionError!,
                    ),
                  ],
                  if (_import.error != null)
                    _Notice(
                      text: _import.error!,
                      palette: palette,
                      isError: true,
                    ),
                  if (!widget.connectImmediately &&
                      _import.isAccepted &&
                      canConnectImported)
                    FilledButton.icon(
                      onPressed: attempt.isBusy ? null : _connectImported,
                      icon: const Icon(Icons.link),
                      label: const Text('连接'),
                    )
                  else if (_import.isAccepted && !canConnectImported)
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
                      payload: _import.pairing!,
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

class _DiscoveredPeerPreview extends StatelessWidget {
  const _DiscoveredPeerPreview({
    required this.name,
    required this.platform,
    required this.discoveryMethod,
    required this.detail,
    required this.connectionDetail,
    required this.verifiedReady,
  });

  final String name;
  final String platform;
  final String discoveryMethod;
  final String detail;
  final String? connectionDetail;
  final bool verifiedReady;

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
                    '对方连接信息',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                NsStatusBadge(
                  label: verifiedReady ? '已验证并就绪' : '待验证',
                  tone: verifiedReady
                      ? NsStatusTone.success
                      : NsStatusTone.warning,
                ),
              ],
            ),
            const SizedBox(height: NearSendSpacing.sm),
            _Field(label: '设备名称', value: name),
            const SizedBox(height: NearSendSpacing.xs),
            _Field(label: '平台', value: platform),
            const SizedBox(height: NearSendSpacing.xs),
            _Field(label: '发现方式', value: discoveryMethod),
            const SizedBox(height: NearSendSpacing.xs),
            _Field(label: '发现状态', value: detail),
            if (connectionDetail != null &&
                connectionDetail!.isNotEmpty) ...<Widget>[
              const SizedBox(height: NearSendSpacing.xs),
              _Field(label: '候选地址', value: connectionDetail!),
            ],
            if (!verifiedReady) ...<Widget>[
              const SizedBox(height: NearSendSpacing.sm),
              const NsInfoBanner(
                title: '发现信息尚未验证',
                message: '设备名称、平台和候选地址只用于发现。完成实时身份与指纹验证前，不能将其视为可信设备。',
                tone: NsStatusTone.warning,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PublishedPayload extends StatelessWidget {
  const _PublishedPayload({
    required this.payload,
    required this.palette,
    required this.deviceName,
    required this.platform,
    required this.persistentIdentity,
  });

  final PairingPayload payload;
  final NearSendColors palette;
  final String deviceName;
  final String platform;
  final bool persistentIdentity;

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
            Center(child: PairingQrView(payload: payload.encode())),
            const SizedBox(height: NearSendSpacing.md),
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
              '对方扫码后会自动校验证书指纹；指纹不符时会阻断连接并要求重新扫码。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: NearSendSpacing.sm),
            // Unsupported platforms and tests still use an explicit ephemeral provider, and must
            // keep stating that limitation. Android/Windows production hide it only after their
            // platform-protected provider has loaded successfully.
            if (!persistentIdentity)
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
            _Field(label: '证书指纹（自动校验）', value: payload.serverFingerprint),
            if (!verified) ...<Widget>[
              const SizedBox(height: NearSendSpacing.sm),
              const NsInfoBanner(
                title: '系统自动校验指纹',
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
