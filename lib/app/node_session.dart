/// The application's node lifetime, as a state a screen can watch.
///
/// ## Why this is not just the runtime
///
/// [NodeRuntime] answers "open the node" and "close the node". What a screen needs is a different
/// question: **has this device got connection information to show yet, and if not, why not**. Those
/// are three states - starting, ready, failed - and each deserves different words, because a user
/// looking at an empty connection screen has to be able to tell "still starting" from "this machine
/// has no Wi-Fi address" from "the app could not find a directory to keep its own files in".
///
/// Folding that into the runtime would put presentation state into a type that has no screen, and
/// leaving it in the widget would make it untestable without pumping frames. So it is its own small
/// type, and the widget listens to it.
///
/// ## Why it resolves its own directory
///
/// The node needs a directory the application owns, and where that is differs per platform. If the
/// caller resolved it before constructing this session, a failure to resolve would have nowhere to
/// go: the app would have to start with no node and no explanation. Taking a resolver instead means
/// the failure happens inside [start], where it becomes a state the screen can render - the same
/// reason the runtime takes a gateway rather than asking which platform it is on.
///
/// ## What it does not decide
///
/// **Identity persistence.** The provider states whether its identity is platform-protected and
/// persistent. The UI only removes the restart warning for that case. A missing or corrupt secure
/// identity becomes a failed node state; this class never falls back to a newly generated identity
/// over an existing database.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:nearsend/app/node_runtime.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/security/installation_identity.dart';
import 'package:nearsend/core/transfer/near_send_node.dart';
import 'package:nearsend/platform/android_file_gateway.dart';
import 'package:nearsend/platform/mdns_discovery_gateway.dart';

/// Where a session is in its life.
enum NodePhase {
  /// Nothing has been opened yet.
  stopped,

  /// Opening: resolving the directory, generating the identity, binding the socket.
  starting,

  /// Open, with connection information published.
  ready,

  /// Opening was refused; [NodeSession.failureReason] says why.
  failed,
}

/// Opens a [NodeRuntime] for one directory.
///
/// A typedef rather than a direct call so a test can state its own runtime, which is the same seam
/// [NodeRuntime] itself keeps for its candidate addresses.
typedef NodeRuntimeFactory = NodeRuntime Function({
  required String directory,
  int port,
  String commonName,
  AndroidFileGateway? gateway,
  List<String>? candidateAddresses,
  InstallationIdentityProvider identityProvider,
});

/// Owns the application's node and publishes the state a screen renders.
class NodeSession extends ChangeNotifier {
  NodeSession({
    required this.resolveDirectory,
    this.port = 0,
    this.commonName = 'NearSend',
    this.gateway,
    this.candidateAddresses,
    this.identityProvider = const EphemeralInstallationIdentityProvider(),
    this.discovery,
    this.openRuntime = NodeRuntime.new,
  });

  /// Where the application's private directory is, resolved when the node is opened.
  final Future<String> Function() resolveDirectory;

  final int port;
  final String commonName;

  /// The platform gateway, when this platform's files are documents rather than paths.
  final AndroidFileGateway? gateway;

  /// The addresses to publish, or null to read them from the network interfaces.
  final List<String>? candidateAddresses;

  final InstallationIdentityProvider identityProvider;
  final MdnsDiscoveryGateway? discovery;

  /// Opens the runtime. Overridable so a test can state its own, and so a failure to open one is
  /// reachable without a broken filesystem.
  final NodeRuntimeFactory openRuntime;

  /// Said when no address on this machine can be reached from a peer.
  static const String noAddressReason = '本机没有可用的局域网地址，无法出示连接信息。请先连接 Wi-Fi。';

  /// Said when the application's own directory cannot be determined.
  static const String noDirectoryReason = '无法确定应用私有目录，本机节点未启动。';

  /// Said for any other refusal, which is not something a user can act on.
  static const String startFailedReason = '本机节点启动失败。';

  NodePhase _phase = NodePhase.stopped;
  NodeRuntime? _runtime;
  PairingPayload? _payload;
  String? _failureReason;
  String? _discoveryFailureReason;
  Future<void>? _attempt;
  bool _disposed = false;

  NodePhase get phase => _phase;

  bool get isReady => _phase == NodePhase.ready && _runtime != null;

  /// The running node, or null when none is.
  NearSendNode? get node => _runtime?.node;

  bool get hasPersistentIdentity =>
      _runtime?.hasPersistentIdentity ?? identityProvider.isPersistent;

  /// The runtime, for the parts of the application that need its gateway or engine.
  NodeRuntime? get runtime => _runtime;

  /// The connection information this device publishes, when it has any (§3).
  PairingPayload? get payload => _payload;

  /// Why the node is not running, as a sentence a user can act on.
  String? get failureReason => _failureReason;

  String? get discoveryFailureReason => _discoveryFailureReason;

  Stream<MdnsDiscoveryEvent> get discoveryEvents =>
      discovery?.events ?? const Stream<MdnsDiscoveryEvent>.empty();

  /// Opens the node, or returns the attempt already in flight.
  ///
  /// Idempotent in both directions: a ready session returns immediately, and concurrent callers
  /// share one attempt rather than racing to open two nodes on one database - which would be two
  /// identities for one installation, and the second would silently invalidate the payload the
  /// first published.
  Future<void> start() {
    if (_phase == NodePhase.ready) {
      return Future<void>.value();
    }
    final Future<void>? inFlight = _attempt;
    if (inFlight != null) {
      return inFlight;
    }
    final Future<void> attempt = _openOnce();
    _attempt = attempt;
    return attempt;
  }

  Future<void> _openOnce() async {
    _set(phase: NodePhase.starting, failureReason: null);

    NodeRuntime? opened;
    try {
      final String directory = await resolveDirectory();
      opened = openRuntime(
        directory: directory,
        port: port,
        commonName: commonName,
        gateway: gateway,
        candidateAddresses: candidateAddresses,
        identityProvider: identityProvider,
      );
      final NearSendNode node = await opened.start();
      _runtime = opened;
      _payload = node.payload;
      _discoveryFailureReason = null;
      final MdnsDiscoveryGateway? mdns = discovery;
      final PairingPayload? payload = node.payload;
      if (mdns != null && payload != null) {
        try {
          await mdns.start(
            MdnsPublication(
              instanceId: payload.sessionId,
              port: node.server.boundPort,
            ),
          );
        } on Object {
          _discoveryFailureReason = '局域网自动发现不可用，仍可使用手动连接。';
        }
      }
      _set(phase: NodePhase.ready, failureReason: null);
    } on Object catch (error) {
      // A runtime that opened and then failed to listen holds an open database. Releasing it is not
      // tidiness: a second attempt on a database whose first handle is still open is exactly the
      // "two identities for one installation" case the idempotence above exists to prevent.
      if (opened != null) {
        await _release(opened);
      }
      _set(phase: NodePhase.failed, failureReason: _reasonFor(error));
    } finally {
      _attempt = null;
    }
  }

  /// Closes the node, waiting for an in-flight open so a stop cannot be undone by it.
  Future<void> stop() async {
    final Future<void>? inFlight = _attempt;
    if (inFlight != null) {
      await inFlight;
    }
    final NodeRuntime? running = _runtime;
    _runtime = null;
    _payload = null;
    _discoveryFailureReason = null;
    try {
      await discovery?.stop();
    } on Object {
      // The node still has to close even if the platform failed to withdraw discovery.
    }
    if (running != null) {
      await _release(running);
    }
    _set(phase: NodePhase.stopped, failureReason: null);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  static Future<void> _release(NodeRuntime runtime) async {
    try {
      await runtime.stop();
    } on Object {
      // The listener is going away either way; what must not happen is an exception here leaving
      // the database handle open, which the `finally` inside the runtime's own stop already covers.
    }
  }

  /// Turns a refusal into words a person can act on.
  ///
  /// Only three conditions are distinguishable to a user, and only one of them has a remedy, so the
  /// rest collapse into a single sentence rather than leaking an exception's text into the UI.
  static String _reasonFor(Object error) {
    if (error is IdentityRecoveryRequired) {
      return '本机安全身份缺失或损坏，已停止启动以避免冒充旧设备。请重新建立本机身份并重新配对。';
    }
    if (error is StateError) {
      return noAddressReason;
    }
    if (error is PlatformFileFailure) {
      return noDirectoryReason;
    }
    return startFailedReason;
  }

  void _set({required NodePhase phase, required String? failureReason}) {
    _phase = phase;
    _failureReason = failureReason;
    if (!_disposed) {
      notifyListeners();
    }
  }
}
