import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:nearsend/app/application/app_settings_repository.dart';
import 'package:nearsend/app/application/radar_controller.dart';
import 'package:nearsend/app/application/settings_controller.dart';
import 'package:nearsend/app/application/space_overview_controller.dart';
import 'package:nearsend/app/application/task_catalog_controller.dart';
import 'package:nearsend/app/node_session.dart';
import 'package:nearsend/app/peer_session.dart';
import 'package:nearsend/features/pairing/presentation/local_device_qr_page.dart';
import 'package:nearsend/app/presentation/app_shell.dart';
import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/app/widgets/near_send_widgets.dart';
import 'package:nearsend/core/network/task_authorization_endpoint.dart';
import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/security/bootstrap_pairing_payload.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/core/storage/peer_repository.dart';
import 'package:nearsend/core/storage/task_authorization_repository.dart';
import 'package:nearsend/core/transfer/near_send_node.dart';
import 'package:nearsend/features/about/presentation/about_page.dart';
import 'package:nearsend/features/settings/presentation/settings_page.dart';
import 'package:nearsend/features/space/presentation/space_overview_page.dart';
import 'package:nearsend/features/tasks/presentation/task_overview_page.dart';
import 'package:nearsend/features/tasks/presentation/task_detail_page.dart';
import 'package:nearsend/features/transfer/application/file_selection_controller.dart';
import 'package:nearsend/features/transfer/application/receive_confirmation.dart';
import 'package:nearsend/features/transfer/application/receiving_flow.dart';
import 'package:nearsend/features/transfer/application/sending_flow.dart';
import 'package:nearsend/features/transfer/application/sending_session.dart';
import 'package:nearsend/features/transfer/application/server_receiving_flow.dart';
import 'package:nearsend/features/transfer/presentation/receive_page.dart';
import 'package:nearsend/features/transfer/presentation/send_page.dart';
import 'package:nearsend/features/transfer/presentation/transfer_pages.dart';
import 'package:nearsend/platform/platform_storage_gateway.dart';
import 'package:nearsend/platform/platform_network_gateway.dart';
import 'package:nearsend/platform/platform_file_actions.dart';
import 'package:nearsend/platform/platform_permission_gateway.dart';
import 'package:nearsend/platform/qr_image_gateway.dart';
import 'package:nearsend/platform/storage_location.dart';
import 'package:nearsend/platform/ble_control_gateway.dart';
import 'package:nearsend/platform/mdns_discovery_gateway.dart';

/// NearSend application root.
///
/// Owns only cross-cutting presentation concerns: theme, routing, the localized app title, and the
/// two sessions that have to outlive any one screen. No business rule may live here — see
/// `docs/architecture/SYSTEM_ARCHITECTURE.md` §3.
///
/// ## Why the connection route takes an argument
///
/// `docs/ui/UI_UX_SPEC.md` §4 gives send and receive the same first step from the user's point of
/// view - establish a connection - and different wording for it. So one route serves both and is
/// told which, rather than two near-identical pages that would drift.
///
/// ## Why the sessions are here and are owned here
///
/// Opening a node has to happen once for the installation, not once per screen, and the connection
/// screen is not the first screen a user sees - so the lifetime cannot belong to a route. It belongs
/// to the application: this widget starts the node when it mounts and stops and disposes it when it
/// is removed. **It therefore takes ownership of whatever it is given**: a caller that hands over a
/// session must not use it afterwards. The alternative - a session handed in and quietly kept alive
/// after the widget is gone - is how a database handle outlives the frame that owned it.
///
/// A null [session] is a legitimate state rather than a test convenience: a build with no node (a
/// widget test that only wants the routes) renders the connection screen's own "nothing to publish
/// yet" note instead of pretending to have connection information.
class NearSendApp extends StatefulWidget {
  const NearSendApp({
    super.key,
    this.session,
    this.peer,
    this.transferIdFactory,
    this.storageGateway,
    this.networkGateway,
    this.bleGateway,
    this.fileActions,
    this.permissionGateway = const MethodChannelPlatformPermissionGateway(),
  });

  /// This device's node, when the application has one.
  final NodeSession? session;

  /// The connection to another device, when one is being made.
  final PeerSession? peer;

  /// Supplies the identifier of a new transfer.
  ///
  /// Injected for the same reason the node's candidate addresses are: a test that has to accept a
  /// transfer on the other side must be able to name it, and §4 makes identifier generation a
  /// protocol concern rather than a platform one.
  final String Function()? transferIdFactory;

  final PlatformStorageGateway? storageGateway;
  final PlatformNetworkGateway? networkGateway;
  final BleControlGateway? bleGateway;
  final PlatformFileActions? fileActions;
  final PlatformPermissionGateway permissionGateway;

  static const String homeRoute = '/';
  static const String aboutRoute = '/about';
  static const String connectRoute = '/connect';
  static const String transferRoute = '/transfer';

  /// Where a chosen selection is sent from. Its own route rather than a dialog, because the flow it
  /// drives outlives a dialog and its figures have to survive a rebuild.
  static const String sendRoute = '/send';

  /// Where an offer from the peer is answered. Its own route for the same reason, and because
  /// receiving a file the user did not ask for must be a screen they chose to be on.
  static const String receiveRoute = '/receive';

  /// The argument `HomePage` passes to the connection screen, so that one screen can serve both
  /// actions and still lead somewhere different afterwards.
  static const String sendArgument = 'send';
  static const String receiveArgument = 'receive';

  /// The receive confirmation, which `docs/ui/UI_UX_SPEC.md` §5 keeps as its own step so the
  /// space check cannot be skipped by accepting on the connection screen.
  static const String receiveConfirmRoute = '/receive-confirm';
  static const String tasksRoute = '/tasks';
  static const String spaceRoute = '/space';
  static const String settingsRoute = '/settings';
  static const String taskDetailRoute = '/task-detail';

  @override
  State<NearSendApp> createState() => _NearSendAppState();
}

class _NearSendAppState extends State<NearSendApp> with WidgetsBindingObserver {
  late final TaskCatalogController _tasks = TaskCatalogController();
  late final SpaceOverviewController _space = SpaceOverviewController(
    gateway: widget.storageGateway,
  );
  late final SettingsController _settings = SettingsController();
  late final RadarController _radar = RadarController();
  StreamSubscription<MdnsDiscoveryEvent>? _radarDiscovery;
  StreamSubscription<BleControlEvent>? _radarBle;
  Future<void> _wifiTransition = Future<void>.value();
  Future<void> _bluetoothTransition = Future<void>.value();
  bool _wifiDesired = false;
  bool _bluetoothDesired = false;
  bool _disposing = false;
  late final PlatformNetworkGateway _networkGateway =
      widget.networkGateway ??
      ((defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.windows)
          ? MethodChannelPlatformNetworkGateway()
          : const UnavailablePlatformNetworkGateway());
  JoinedWifiLease? _joinedWifi;
  Timer? _pairingPresenceTimer;
  bool _probingPeer = false;
  bool _outgoingRecent = false;
  final Stopwatch _outgoingAge = Stopwatch();
  String? _outgoingName;
  int _presenceTicks = 0;

  void _syncPairingPresence() {
    if (_disposing) return;
    final peer = widget.peer;
    final payload = peer?.peer;
    _radar.syncQrSessions(
      widget.session?.node?.pairing.pairedClients ?? const [],
      outgoing: payload == null
          ? null
          : RadarDevice(
              id: 'qr-out:${payload.serverFingerprint}',
              name: _outgoingName ?? '已扫码设备',
              detail: '二维码配对 · 本次会话',
              isKnown: true,
              isReady:
                  peer!.isConnected &&
                  _outgoingRecent &&
                  _outgoingAge.elapsed.inSeconds < 30,
              isRevoked: false,
              discoveryMethod: '二维码配对',
            ),
    );
  }

  Future<void> _probePairedPeer() async {
    final peer = widget.peer;
    final client = peer?.client;
    if (_probingPeer || client == null || peer?.isConnected != true) return;
    _probingPeer = true;
    bool recent = false;
    try {
      // Existing authenticated, read-only endpoint: also refreshes server presence.
      await client.offers().timeout(const Duration(seconds: 5));
      recent = true;
    } on Object {
      // A failed probe only changes presence; it does not cancel a transfer.
      recent = false;
    } finally {
      _probingPeer = false;
    }
    if (_disposing || widget.peer?.client != client) return;
    _outgoingRecent = recent;
    if (recent) {
      _outgoingAge
        ..reset()
        ..start();
    }
    _syncPairingPresence();
  }

  /// The sending flow, once there is a verified peer and a node to send from.
  ///
  /// Created on a successful connection rather than at startup, because a flow with no peer would be
  /// a screen whose send button has nothing behind it - the state this whole task exists to remove.
  SendingFlow? _flow;

  /// The receiving flow for the same connection: what the peer is offering, and the answer to it.
  ReceivingFlow? _receiving;

  /// What **this** device is being asked to accept, which needs no connection at all.
  ///
  /// A client that paired with this node proposes to it and pushes whether or not this device ever
  /// paired back, so a screen for that cannot wait for a connection to exist. It needs the node and
  /// nothing else.
  ServerReceivingFlow? _incoming;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _radarBle = widget.bleGateway?.events.listen(_radar.handleBle);
    // Not awaited: the first frame must not wait for a socket and a database, and the session
    // publishes its own phases for the screen to render in the meantime.
    unawaited(_openNode());
  }

  /// Starts the node and, once it is up, prepares to answer what is pushed to it.
  Future<void> _openNode() async {
    final NodeSession? session = widget.session;
    if (session == null) {
      return;
    }
    await session.start();
    final NearSendNode? node = session.node;
    if (node == null) {
      return;
    }
    _incoming = ServerReceivingFlow(
      engine: node.engine,
      outputPlans: node.outputPlans,
      now: () => DateTime.now().millisecondsSinceEpoch,
    );
    _tasks.attach(node.database);
    _settings.attach(AppSettingsRepository(node.database));
    _radar.attach(PeerRepository(node.database));
    _syncPairingPresence();
    _pairingPresenceTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _syncPairingPresence();
      if (++_presenceTicks % 10 == 0) unawaited(_probePairedPeer());
    });
    final MdnsDiscoveryGateway? discovery = session.discovery;
    if (discovery != null) {
      _radarDiscovery = discovery.events.listen(_radar.handleMdns);
    }
    unawaited(_space.refresh());
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _disposing = true;
    _pairingPresenceTimer?.cancel();
    _wifiDesired = false;
    _bluetoothDesired = false;
    WidgetsBinding.instance.removeObserver(this);
    final NodeSession? session = widget.session;
    if (session != null) {
      // Stopped before it is disposed, because `stop` is what closes the listener and the database
      // and it notifies listeners while doing so. A session disposed underneath a running node
      // would leave the node listening with no owner.
      unawaited(session.stop().whenComplete(session.dispose));
    }
    widget.peer?.dispose();
    _flow?.dispose();
    _receiving?.dispose();
    _incoming?.dispose();
    _tasks.dispose();
    _space.dispose();
    _settings.dispose();
    unawaited(_radarDiscovery?.cancel());
    unawaited(_radarBle?.cancel());
    unawaited(widget.bleGateway?.stop());
    _radar.dispose();
    final JoinedWifiLease? joinedWifi = _joinedWifi;
    if (joinedWifi != null) {
      unawaited(_releaseJoinedWifi(joinedWifi));
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposing || state == AppLifecycleState.resumed) return;
    if (_wifiDesired) {
      _requestWifiReady(false);
    }
    if (_bluetoothDesired) {
      _requestBluetoothReady(false);
    }
  }

  void _requestWifiReady(bool value) {
    if (_disposing) return;
    _wifiDesired = value;
    _wifiTransition = _wifiTransition
        .catchError((Object _) {})
        .then((_) => _applyWifiReady(value));
  }

  Future<void> _applyWifiReady(bool value) async {
    final NodeSession? session = widget.session;
    if (!value) {
      _radar.markWifiStopping();
      if (session != null) {
        await session.setDiscoveryEnabled(false).catchError((Object _) {});
      }
      if (!_disposing) _radar.markWifiOff();
      return;
    }

    if (session?.phase != NodePhase.ready || session?.payload == null) {
      _radar.markWifiError('本机节点尚未就绪，请稍后重试。');
      return;
    }
    if (session!.discovery == null) {
      _radar.markWifiError('当前平台没有可用的 Wi-Fi 局域网发现渠道。');
      return;
    }
    _radar.markWifiStarting();
    try {
      await session.setDiscoveryEnabled(
        true,
        deviceName: _settings.settings.deviceName,
        platform: defaultTargetPlatform.name,
      );
    } on Object {
      if (!_disposing && _wifiDesired) {
        _radar.markWifiError('Wi-Fi 局域网发现不可用。');
      }
      return;
    }
    if (_disposing || !_wifiDesired) return;
    if (session.discovery!.isRunning) {
      _radar.markWifiReady();
    } else {
      _radar.markWifiError(session.discoveryFailureReason ?? 'Wi-Fi 局域网发现不可用。');
    }
  }

  void _requestBluetoothReady(bool value) {
    if (_disposing) return;
    _bluetoothDesired = value;
    _bluetoothTransition = _bluetoothTransition
        .catchError((Object _) {})
        .then((_) => _applyBluetoothReady(value));
  }

  Future<void> _applyBluetoothReady(bool value) async {
    final NodeSession? session = widget.session;
    final BleControlGateway? ble = widget.bleGateway;
    if (!value) {
      _radar.markBluetoothStopping();
      if (ble != null) {
        await ble.stop().catchError((Object _) {});
      }
      if (!_disposing) _radar.markBluetoothOff();
      return;
    }

    final String? sessionId = session?.payload?.sessionId;
    if (session?.phase != NodePhase.ready || sessionId == null) {
      _radar.markBluetoothError('本机节点尚未就绪，请稍后重试。');
      return;
    }
    if (ble == null) {
      _radar.markBluetoothError('当前平台没有可用的蓝牙发现渠道。');
      return;
    }
    _radar.markBluetoothStarting();
    try {
      if (!await ble.requestAuthorization()) {
        if (!_disposing && _bluetoothDesired) {
          _radar.markBluetoothError('蓝牙权限未授予。');
        }
        return;
      }
      await ble.start(
        BlePublication.fromInstanceId(
          sessionId,
          deviceName: _settings.settings.deviceName,
        ),
      );
    } on Object {
      if (!_disposing && _bluetoothDesired) {
        _radar.markBluetoothError('蓝牙发现不可用。');
      }
      return;
    }
    if (_disposing || !_bluetoothDesired) return;
    if (ble.isRunning) {
      _radar.markBluetoothReady();
    } else {
      _radar.markBluetoothError('蓝牙发现不可用。');
    }
  }

  /// Pairs with the device that published [payload], and prepares for either direction.
  ///
  /// Both flows are built once the peer proved its identity: a client for an unverified peer must
  /// not exist, and `PeerSession` is what guarantees it does not. Which of them a screen uses is the
  /// user's choice - the same connection serves sending and receiving, which is why they are made
  /// together rather than on the way into a screen.
  Future<bool> connect(PairingPayload payload, {String? displayName}) async {
    final PeerSession? peer = widget.peer;
    if (peer == null) {
      return false;
    }
    _outgoingRecent = false;
    final bool connected = await peer.connect(
      payload,
      displayLabel: _settings.settings.deviceName,
    );
    _outgoingRecent = connected;
    if (connected) {
      _outgoingAge
        ..reset()
        ..start();
    }
    _outgoingName = displayName;
    _syncPairingPresence();
    final NearSendNode? node = widget.session?.node;
    if (!connected || node == null) {
      return false;
    }
    _flow?.dispose();
    // The session this device published: a peer that pairs with it becomes a client of this node,
    // which is what makes an offer of ours visible to it (§6 lists offers to the bound session).
    final String? ownSessionId = widget.session?.payload?.sessionId;
    _flow = SendingFlow(
      session: SendingSession(engine: node.engine, wire: peer.client!),
      // The gateway is the platform's own, and null on a platform whose files are paths - which is
      // what makes the send screen offer a path field there instead of a picker that cannot work.
      selection: FileSelectionController(
        gateway: widget.session?.gateway,
        permissionGateway: widget.permissionGateway,
      ),
      now: () => DateTime.now().millisecondsSinceEpoch,
      transferIdFactory: widget.transferIdFactory,
      // Asked at send time, not now: the peer may pair with this device after this screen exists,
      // and that is precisely the moment the answer changes.
      ownSessionId: ownSessionId,
      peerHasPaired: () =>
          ownSessionId != null && node.pairing.hasPairedClient(ownSessionId),
      mirror: node.mirror,
    );
    _receiving?.dispose();
    _receiving = ReceivingFlow(
      engine: node.engine,
      wire: peer.client!,
      outputPlans: node.outputPlans,
      now: () => DateTime.now().millisecondsSinceEpoch,
    );
    if (mounted) {
      setState(() {});
    }
    return true;
  }

  Future<void> connectBootstrap(BootstrapPairingPayload payload) async {
    JoinedWifiLease? joined;
    final BootstrapWifiOffer? wifi = payload.wifi;
    try {
      if (wifi != null) {
        final JoinedWifiLease? previous = _joinedWifi;
        if (previous != null) {
          await _releaseJoinedWifi(previous);
        }
        joined = await _networkGateway.joinWifi(
          ssid: wifi.ssid,
          passphrase: wifi.passphrase,
          security: wifi.security == 'wpa3'
              ? WifiSecurity.wpa3
              : WifiSecurity.wpa2,
        );
        _joinedWifi = joined;
      }
      if (!await connect(payload.pairing) && joined != null) {
        await _releaseJoinedWifi(joined);
      }
    } on Object {
      if (joined != null) {
        await _releaseJoinedWifi(joined);
      }
    }
  }

  Future<void> _releaseJoinedWifi(JoinedWifiLease lease) async {
    try {
      await _networkGateway.releaseJoinedWifi(lease.leaseId);
    } on Object {
      // Cleanup is best effort. The platform also owns lifecycle cleanup.
    } finally {
      if (_joinedWifi?.leaseId == lease.leaseId) _joinedWifi = null;
    }
  }

  /// Where the connection screen leads once the peer has proved its identity.
  ///
  /// Null when the flow that screen would need has not been built, which is the same rule the
  /// connect button follows: a control that cannot act is not rendered.
  String? _continueTarget(bool receiving) => receiving
      ? (_receiving == null && _incoming == null
            ? null
            : NearSendApp.receiveRoute)
      : (_flow == null ? null : NearSendApp.sendRoute);

  String get _connectionLabel => switch (widget.session?.phase) {
    NodePhase.ready => '本机已就绪',
    NodePhase.starting => '正在启动',
    NodePhase.failed => '节点不可用',
    NodePhase.stopped || null => '未启动',
  };

  NsStatusTone get _connectionTone => switch (widget.session?.phase) {
    NodePhase.ready => NsStatusTone.success,
    NodePhase.starting => NsStatusTone.active,
    NodePhase.failed => NsStatusTone.error,
    NodePhase.stopped || null => NsStatusTone.warning,
  };

  Future<StorageLocationRef?> _pickReceiveDirectory() async {
    final PlatformStorageGateway? gateway = widget.storageGateway;
    if (gateway == null || !gateway.supportsDirectorySelection) return null;
    final PlatformPermissionState permission = await ensurePlatformPermission(
      widget.permissionGateway,
      PlatformPermissionKind.files,
    );
    if (!permission.allowsUse) {
      throw StateError('system directory access is unavailable');
    }
    return gateway.pickReceiveDirectory();
  }

  /// The storage context a pushed transfer is accepted with.
  ///
  /// **The availability is unknown on purpose.** This build has no way to measure a volume - there
  /// is no Dart API for free space and no platform channel for it yet - and §6 makes the acceptance
  /// commit to a space estimate. Inventing a figure would be worse than admitting there is none, so
  /// the estimate is recorded as unknown, the flow refuses only a *proven* shortfall, and the screen
  /// says out loud that no pre-check was done. Adding the measurement is a platform task, and until
  /// it exists this is the honest arrangement.
  Future<ReceiverStorageContext> _storageContext(
    StorageLocationRef saveLocation,
  ) async {
    const VolumeId appPrivate = VolumeId('app-private');
    final PlatformStorageGateway gateway =
        widget.storageGateway ?? const UnknownPlatformStorageGateway();
    final StorageMeasurement measurement = await gateway.measureFreeSpace(
      location: saveLocation,
    );
    return ReceiverStorageContext(
      stagingVolume: appPrivate,
      exportVolume: measurement.volume,
      databaseVolume: appPrivate,
      availability: <VolumeId, VolumeAvailability>{
        appPrivate: const VolumeAvailability.unknown(),
        measurement.volume: measurement.availability,
      },
      saveLocationRef: saveLocation.opaqueValue,
    );
  }

  Future<SpaceEstimateSnapshot?> _measureIncomingSpace(
    ServerOffer offer,
    StorageLocationRef saveLocation,
  ) async {
    final ServerReceivingFlow? incoming = _incoming;
    if (incoming == null) {
      return null;
    }
    final ReceiverStorageContext context = await _storageContext(saveLocation);
    return incoming.estimateFor(offer, context);
  }

  /// The peer state, as the connection screen renders it.
  ///
  /// A mapping rather than passing the session through: the screen is a renderer, and the two
  /// enums exist so that neither layer has to know the other's type.
  ConnectionAttempt get attempt {
    final PeerSession? peer = widget.peer;
    if (peer == null) {
      return const ConnectionAttempt();
    }
    switch (peer.phase) {
      case PeerPhase.idle:
        return const ConnectionAttempt();
      case PeerPhase.connecting:
        return const ConnectionAttempt(
          phase: ConnectionAttemptPhase.connecting,
        );
      case PeerPhase.connected:
        return const ConnectionAttempt(phase: ConnectionAttemptPhase.connected);
      case PeerPhase.failed:
        return ConnectionAttempt(
          phase: ConnectionAttemptPhase.failed,
          reason: peer.failureReason,
          peerFingerprint: peer.presentedFingerprint,
          pinMismatched: peer.pinMismatched,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (BuildContext context, Widget? child) {
        final ThemeMode themeMode =
            switch (_settings.settings.themePreference) {
              AppThemePreference.system => ThemeMode.system,
              AppThemePreference.light => ThemeMode.light,
              AppThemePreference.dark => ThemeMode.dark,
            };
        return MaterialApp(
          title: 'NearSend',
          debugShowCheckedModeBanner: false,
          theme: buildNearSendTheme(Brightness.light),
          darkTheme: buildNearSendTheme(Brightness.dark),
          themeMode: themeMode,
          initialRoute: NearSendApp.homeRoute,
          routes: <String, WidgetBuilder>{
            NearSendApp.homeRoute: (BuildContext context) => NearSendAppShell(
              tasks: _tasks,
              space: _space,
              settings: _settings,
              radar: _radar,
              deviceName: _settings.settings.deviceName,
              connectionLabel: _connectionLabel,
              connectionTone: _connectionTone,
              onSend: () => Navigator.of(context).pushNamed(
                _flow != null && widget.peer?.isConnected == true
                    ? NearSendApp.sendRoute
                    : NearSendApp.connectRoute,
                arguments: 'send',
              ),
              onReceive: () => Navigator.of(context).pushNamed(
                _receiving != null ||
                        (_incoming != null &&
                            _radar.pairedDevices.any(
                              (device) => device.isReady,
                            ))
                    ? NearSendApp.receiveRoute
                    : NearSendApp.connectRoute,
                arguments: 'receive',
              ),
              onContinueTask: () =>
                  Navigator.of(context).pushNamed(NearSendApp.tasksRoute),
              onWifiReadyChanged: _requestWifiReady,
              onBluetoothReadyChanged: _requestBluetoothReady,
              onRadarDevicePressed: (RadarDevice device) =>
                  Navigator.of(context)
                      .pushNamed(NearSendApp.connectRoute, arguments: device),
            ),
            '/local-qr': (_) => LocalDeviceQrPage(
              session: widget.session,
              radar: _radar,
              deviceName: _settings.settings.deviceName,
            ),
            NearSendApp.aboutRoute: (_) => const AboutPage(),
            NearSendApp.tasksRoute: (_) => TaskOverviewPage(controller: _tasks),
            NearSendApp.spaceRoute: (_) =>
                SpaceOverviewPage(controller: _space),
            NearSendApp.settingsRoute: (_) => SettingsPage(
              controller: _settings,
              space: _space,
              permissionGateway: widget.permissionGateway,
            ),
            NearSendApp.taskDetailRoute: (BuildContext context) {
              final Object? argument = ModalRoute.of(context)
                  ?.settings
                  .arguments;
              if (argument is! String) {
                return const Scaffold(
                  body: NsErrorState(
                    title: '缺少任务标识',
                    message: '无法打开没有任务 ID 的详情页面。',
                  ),
                );
              }
              return TaskDetailPage(
                controller: _tasks,
                taskId: argument,
                fileActions: widget.fileActions,
              );
            },
            NearSendApp.connectRoute: (BuildContext context) {
              // Which action the user came here for, so one connection screen can lead to the send flow
              // or the receive flow without duplicating itself.
              final Object? routeArgument = ModalRoute.of(context)
                  ?.settings
                  .arguments;
              final bool receiving =
                  routeArgument == NearSendApp.receiveArgument;
              final bool pairingOnly =
                  routeArgument == 'pair' || routeArgument is RadarDevice;
              final RadarDevice? selectedDevice = routeArgument is RadarDevice
                  ? routeArgument
                  : null;
              return ListenableBuilder(
                // Both sessions: the published payload arrives asynchronously, and a connection attempt
                // changes without any navigation happening.
                listenable: Listenable.merge(<Listenable?>[
                  widget.session,
                  widget.peer,
                ]),
                builder: (BuildContext context, Widget? _) {
                  final NodeSession? session = widget.session;
                  return ConnectionPage(
                    payload: session?.payload,
                    starting: session?.phase == NodePhase.starting,
                    // Only a *failed* node has a reason to state. A node that is starting has none, and a
                    // build with no node at all has nothing to say beyond the empty-session note.
                    unavailableReason: session?.phase == NodePhase.failed
                        ? session!.failureReason
                        : null,
                    connection: attempt,
                    onConnect: widget.peer == null
                        ? null
                        : (payload) => connect(
                            payload,
                            displayName: selectedDevice?.name,
                          ),
                    onConnectBootstrap: widget.peer == null
                        ? null
                        : connectBootstrap,
                    enableCameraScanner:
                        defaultTargetPlatform == TargetPlatform.android ||
                        defaultTargetPlatform == TargetPlatform.iOS,
                    qrImageGateway:
                        defaultTargetPlatform == TargetPlatform.windows
                        ? MethodChannelQrImageGateway()
                        : null,
                    permissionGateway: widget.permissionGateway,
                    onContinue: pairingOnly && attempt.isConnected
                        ? () => Navigator.of(context).pop()
                        : _continueTarget(receiving) == null
                        ? null
                        : () =>
                              Navigator.of(context)
                                  .pushNamed(_continueTarget(receiving)!),
                    continueLabel: pairingOnly
                        ? '返回首页'
                        : receiving
                        ? ConnectionPage.continueLabelReceive
                        : ConnectionPage.continueLabelSend,
                    localDeviceName: _settings.settings.deviceName,
                    localPlatform: defaultTargetPlatform.name,
                    peerDeviceName: selectedDevice?.name ?? '对端设备名称未提供',
                    peerPlatform: selectedDevice?.platform ?? '对端平台未提供',
                    selectedPeerName: selectedDevice?.name,
                    selectedPeerPlatform: selectedDevice?.platform,
                    selectedPeerDiscoveryMethod:
                        selectedDevice?.discoveryMethod,
                    selectedPeerDetail: selectedDevice?.detail,
                    selectedPeerConnectionDetail:
                        selectedDevice?.connectionDetail,
                    selectedPeerReady: selectedDevice?.isReady ?? false,
                    persistentLocalIdentity:
                        session?.hasPersistentIdentity ?? false,
                  );
                },
              );
            },
            NearSendApp.receiveRoute: (BuildContext context) {
              final ReceivingFlow? receiving = _receiving;
              final ServerReceivingFlow? incoming = _incoming;
              if (receiving == null && incoming == null) {
                // Reachable only by a hand-typed route before the node is up: there is nothing to ask
                // and nothing to be pushed yet.
                return const Scaffold(
                  body: Center(child: Text('本机节点尚未就绪，无法接收。')),
                );
              }
              return ListenableBuilder(
                listenable: Listenable.merge(<Listenable?>[
                  receiving,
                  incoming,
                ]),
                builder: (BuildContext context, Widget? _) => ReceivePage(
                  phase: receiving?.phase ?? ReceivePhase.idle,
                  offers: receiving?.offers ?? const <OfferSummary>[],
                  progress: receiving?.progress,
                  fileName: receiving?.currentFileName,
                  fileNumber: receiving?.currentFileNumber ?? 0,
                  fileCount: receiving?.fileCount ?? 0,
                  failureReason: receiving?.failureReason,
                  savedPaths: receiving?.savedPaths ?? const <String>[],
                  savedFiles: receiving?.savedFiles ?? const [],
                  // Both halves are asked, because §6 announces neither: a client's view of what the
                  // peer offers, and this device's own view of what is being pushed to it.
                  onRefresh: () async {
                    await receiving?.refresh();
                    await incoming?.refresh();
                  },
                  onPreview: (offer) async =>
                      await receiving?.preview(offer) ??
                      const <ReceiveFilePreview>[],
                  onAccept: (offer, confirmation) async =>
                      await receiving?.accept(
                        offer,
                        saveLocationRef: confirmation.location.opaqueValue,
                        outputNames: confirmation.outputNames,
                      ) ??
                      false,
                  pushOffers: incoming?.pending ?? const <ServerOffer>[],
                  pushPhase: incoming?.phase ?? ServerReceivePhase.waiting,
                  pushSpaceVerdict: incoming?.spaceVerdict,
                  pushSpaceEstimate: incoming?.spaceEstimate,
                  pushFailureReason: incoming?.failureReason,
                  pushSavedPaths: incoming?.savedPaths ?? const <String>[],
                  pushSavedFiles: incoming?.savedFiles ?? const [],
                  fileActions: widget.fileActions,
                  onCheckPushSpace: _measureIncomingSpace,
                  onPreviewPush: incoming == null
                      ? null
                      : (offer) async => incoming.preview(offer),
                  initialLocation: _settings.settings.defaultReceiveLocation,
                  onPickLocation:
                      widget.storageGateway == null ||
                          !widget.storageGateway!.supportsDirectorySelection
                      ? null
                      : _pickReceiveDirectory,
                  onValidateLocation:
                      widget.storageGateway?.validateReceiveLocation,
                  onRememberDefault: _settings.updateDefaultReceiveLocation,
                  onAcceptPush: incoming == null
                      ? null
                      : (offer, confirmation) async => incoming.accept(
                          offer,
                          context: await _storageContext(confirmation.location),
                          targetRef: confirmation.location.opaqueValue,
                          outputNames: confirmation.outputNames,
                        ),
                ),
              );
            },
            NearSendApp.sendRoute: (BuildContext context) {
              final SendingFlow? flow = _flow;
              if (flow == null) {
                // Reachable only by a hand-typed route: the send action is what creates a flow, and a
                // screen without one would have a send button with nothing behind it.
                return const Scaffold(
                  body: Center(child: Text('还没有建立连接，无法发送。')),
                );
              }
              return ListenableBuilder(
                listenable: flow,
                builder: (BuildContext context, Widget? _) {
                  // A picker exists on a platform whose files are documents, and a path field exists on
                  // a platform whose files are paths. Both are the same selection underneath.
                  final bool hasPicker = flow.selection.hasPicker;
                  return SendPage(
                    report: flow.report,
                    phase: flow.phase,
                    progress: flow.progress,
                    fileName: flow.currentFileName,
                    fileNumber: flow.currentFileNumber,
                    fileCount: flow.fileCount,
                    failureReason: flow.failureReason,
                    onPick: hasPicker ? flow.pick : null,
                    onAddPath: hasPicker
                        ? null
                        : (String path) => flow.addPaths(<String>[path]),
                    onSend: flow.send,
                    onClear: flow.clear,
                  );
                },
              );
            },
          },
        );
      },
    );
  }
}
