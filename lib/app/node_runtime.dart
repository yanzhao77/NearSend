import 'dart:io';

import 'package:nearsend/core/storage/source_bytes.dart';
import 'package:nearsend/core/transfer/near_send_node.dart';
import 'package:nearsend/core/transfer/transfer_engine.dart';
import 'package:nearsend/platform/android_file_gateway.dart';

/// Owns the application's one [NearSendNode], and the answers it needs before it can start.
///
/// ## Why this is its own type
///
/// The remaining gap in this build is not a screen - every screen exists and is tested. It is a
/// **lifetime**: nothing in `lib/app/` ever opened a node, so the selection screen had no
/// `SendingSession` to call and its send button had nothing behind it. Making that a named type
/// rather than a few lines inside a widget is what lets it be tested without a widget, and what
/// keeps the question "when is the node open" answerable in one place.
///
/// ## What it deliberately does not decide
///
/// **It does not persist the identity**, and it does not pretend to. `NearSendNode.open` mints a
/// fresh TLS identity every time, so the pin a peer recorded last launch will not match this one.
/// Identity persistence is an open item with its own consequences - where the private key lives, in
/// platform secure storage, and what re-pairing means when it is missing - and inventing a
/// half-answer here (a key file next to the database, say) would be exactly the "cheap secret store"
/// `AGENTS.md` §5 rules out. So [start] mints a new identity and the UI says so; the day
/// persistence lands, [start] is where it will be used and the UI note is what must change with it.
///
/// ## Why it takes its dependencies rather than building them
///
/// [gateway] is null on every platform whose files are paths, and a SAF gateway on Android. Passing
/// it in means this class never has to ask which platform it is on, which is the same reason the
/// engine takes a resolver instead of branching.
class NodeRuntime {
  NodeRuntime({
    required this.directory,
    this.port = 0,
    this.commonName = 'NearSend',
    this.gateway,
    this.candidateAddresses,
  });

  /// The application-private directory holding the database and staging.
  ///
  /// App-private on purpose: §5.1 keeps a manifest path away from the filesystem and staging is not
  /// something the user should meet, so this is never a user-chosen location.
  final String directory;

  /// The port to listen on; `0` asks the system for a free one.
  final int port;

  final String commonName;

  /// The platform file gateway, when this platform's files are documents rather than paths.
  final AndroidFileGateway? gateway;

  /// The addresses to publish, or null to read them from the network interfaces.
  ///
  /// Injectable so a test can state them instead of depending on the machine it runs on.
  final List<String>? candidateAddresses;

  NearSendNode? _node;

  /// The running node, or null before [start] and after [stop].
  NearSendNode? get node => _node;

  bool get isRunning => _node != null;

  /// Opens and starts the node, and issues the first pairing payload.
  ///
  /// Idempotent: calling it twice returns the node that is already running rather than opening a
  /// second one. Two nodes on one database would be two identities for one installation, and the
  /// second would silently invalidate the payload the first published - the same reasoning §3 uses
  /// for re-issued QR codes.
  Future<NearSendNode> start() async {
    final NearSendNode? existing = _node;
    if (existing != null) {
      return existing;
    }

    final List<String> candidates = candidateAddresses ?? await lanAddresses();
    if (candidates.isEmpty) {
      // Refused rather than started with no candidate: §3's payload has to offer an address, and a
      // node reachable only on loopback would publish a QR code no peer on the LAN could use.
      throw StateError(
        'no LAN address is available, so there is nothing to put in the connection information',
      );
    }

    final NearSendNode opened = await NearSendNode.open(
      directory: directory,
      candidateAddresses: candidates,
      port: port,
      commonName: commonName,
      sourceResolver: _resolverFor(gateway),
    );
    await opened.start();
    _node = opened;

    // §3's payload is issued after the socket is bound, because a candidate carries a port and a
    // payload built earlier would offer one nothing is listening on.
    opened.openPairingSession();
    return opened;
  }

  /// Stops the node and closes its database.
  ///
  /// Safe to call when nothing is running. The order matters: the listener is closed before the
  /// database, so a request cannot arrive after the connection it would read from is gone.
  Future<void> stop() async {
    final NearSendNode? running = _node;
    _node = null;
    if (running == null) {
      return;
    }
    await running.stop();
    running.close();
  }

  /// The addresses a peer on the local network could reach this machine by.
  ///
  /// Loopback is excluded because it is not reachable from the other device, and link-local
  /// addresses are excluded because they mean "no DHCP answer" rather than a usable address. An
  /// empty result is a real answer - the device is not on a network - and [start] refuses on it
  /// rather than publishing an address that cannot work.
  static Future<List<String>> lanAddresses() async {
    final List<String> found = <String>[];
    for (final NetworkInterface interface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final InternetAddress address in interface.addresses) {
        if (address.isLoopback || address.address.startsWith('169.254.')) {
          continue;
        }
        if (!found.contains(address.address)) {
          found.add(address.address);
        }
      }
    }
    return found;
  }

  /// The resolver this platform reads its sources with.
  ///
  /// A path by default; a document when a gateway is supplied. Kept here rather than in the engine
  /// so the engine never has to know which platform it is on.
  static SourceBytes Function(String, int) _resolverFor(
    AndroidFileGateway? gateway,
  ) {
    if (gateway == null) {
      return TransferEngine.defaultSourceResolver;
    }
    return (String ref, int size) => ref.startsWith('content://')
        ? SafSourceBytes(gateway: gateway, uri: ref, providerReportedSize: size)
        : FileSourceBytes(File(ref));
  }
}
