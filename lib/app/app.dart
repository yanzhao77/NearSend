import 'dart:async';

import 'package:flutter/material.dart';

import 'package:nearsend/app/node_session.dart';
import 'package:nearsend/app/peer_session.dart';
import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/transfer/near_send_node.dart';
import 'package:nearsend/features/about/presentation/about_page.dart';
import 'package:nearsend/features/home/presentation/home_page.dart';
import 'package:nearsend/features/transfer/application/file_selection_controller.dart';
import 'package:nearsend/features/transfer/application/receiving_flow.dart';
import 'package:nearsend/features/transfer/application/sending_flow.dart';
import 'package:nearsend/features/transfer/application/sending_session.dart';
import 'package:nearsend/features/transfer/presentation/receive_page.dart';
import 'package:nearsend/features/transfer/presentation/send_page.dart';
import 'package:nearsend/features/transfer/presentation/transfer_pages.dart';

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

  @override
  State<NearSendApp> createState() => _NearSendAppState();
}

class _NearSendAppState extends State<NearSendApp> {
  /// The sending flow, once there is a verified peer and a node to send from.
  ///
  /// Created on a successful connection rather than at startup, because a flow with no peer would be
  /// a screen whose send button has nothing behind it - the state this whole task exists to remove.
  SendingFlow? _flow;

  /// The receiving flow for the same connection: what the peer is offering, and the answer to it.
  ReceivingFlow? _receiving;

  @override
  void initState() {
    super.initState();
    // Not awaited: the first frame must not wait for a socket and a database, and the session
    // publishes its own phases for the screen to render in the meantime.
    unawaited(widget.session?.start() ?? Future<void>.value());
  }

  @override
  void dispose() {
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
    super.dispose();
  }

  /// Pairs with the device that published [payload], and prepares for either direction.
  ///
  /// Both flows are built once the peer proved its identity: a client for an unverified peer must
  /// not exist, and `PeerSession` is what guarantees it does not. Which of them a screen uses is the
  /// user's choice - the same connection serves sending and receiving, which is why they are made
  /// together rather than on the way into a screen.
  Future<void> connect(PairingPayload payload) async {
    final PeerSession? peer = widget.peer;
    if (peer == null) {
      return;
    }
    final bool connected = await peer.connect(payload);
    final NearSendNode? node = widget.session?.node;
    if (!connected || node == null) {
      return;
    }
    _flow?.dispose();
    _flow = SendingFlow(
      session: SendingSession(engine: node.engine, wire: peer.client!),
      // The gateway is the platform's own, and null on a platform whose files are paths - which is
      // what makes the send screen offer a path field there instead of a picker that cannot work.
      selection: FileSelectionController(gateway: widget.session?.gateway),
      now: () => DateTime.now().millisecondsSinceEpoch,
      transferIdFactory: widget.transferIdFactory,
    );
    _receiving?.dispose();
    _receiving = ReceivingFlow(
      engine: node.engine,
      wire: peer.client!,
      now: () => DateTime.now().millisecondsSinceEpoch,
    );
    if (mounted) {
      setState(() {});
    }
  }

  /// Where the connection screen leads once the peer has proved its identity.
  ///
  /// Null when the flow that screen would need has not been built, which is the same rule the
  /// connect button follows: a control that cannot act is not rendered.
  String? _continueTarget(bool receiving) => receiving
      ? (_receiving == null ? null : NearSendApp.receiveRoute)
      : (_flow == null ? null : NearSendApp.sendRoute);

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
    return MaterialApp(
      title: 'NearSend',
      debugShowCheckedModeBanner: false,
      theme: buildNearSendTheme(Brightness.light),
      darkTheme: buildNearSendTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      initialRoute: NearSendApp.homeRoute,
      routes: <String, WidgetBuilder>{
        NearSendApp.homeRoute: (_) => const HomePage(),
        NearSendApp.aboutRoute: (_) => const AboutPage(),
        NearSendApp.connectRoute: (BuildContext context) {
          // Which action the user came here for, so one connection screen can lead to the send flow
          // or the receive flow without duplicating itself.
          final bool receiving =
              ModalRoute.of(context)?.settings.arguments ==
              NearSendApp.receiveArgument;
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
                onConnect: widget.peer == null ? null : connect,
                onContinue: _continueTarget(receiving) == null
                    ? null
                    : () =>
                          Navigator.of(context)
                              .pushNamed(_continueTarget(receiving)!),
                continueLabel: receiving
                    ? ConnectionPage.continueLabelReceive
                    : ConnectionPage.continueLabelSend,
              );
            },
          );
        },
        NearSendApp.receiveRoute: (BuildContext context) {
          final ReceivingFlow? receiving = _receiving;
          if (receiving == null) {
            // Reachable only by a hand-typed route: a connection is what creates the flow, and a
            // screen without one could only show an empty list forever.
            return const Scaffold(body: Center(child: Text('还没有建立连接，无法接收。')));
          }
          return ListenableBuilder(
            listenable: receiving,
            builder: (BuildContext context, Widget? _) => ReceivePage(
              phase: receiving.phase,
              offers: receiving.offers,
              progress: receiving.progress,
              fileName: receiving.currentFileName,
              fileNumber: receiving.currentFileNumber,
              fileCount: receiving.fileCount,
              failureReason: receiving.failureReason,
              savedPaths: receiving.savedPaths,
              onRefresh: receiving.refresh,
              onAccept: (offer, saveLocation) =>
                  receiving.accept(offer, saveLocationRef: saveLocation),
            ),
          );
        },
        NearSendApp.sendRoute: (BuildContext context) {
          final SendingFlow? flow = _flow;
          if (flow == null) {
            // Reachable only by a hand-typed route: the send action is what creates a flow, and a
            // screen without one would have a send button with nothing behind it.
            return const Scaffold(body: Center(child: Text('还没有建立连接，无法发送。')));
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
  }
}
