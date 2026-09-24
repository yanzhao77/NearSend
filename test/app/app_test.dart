import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/app.dart';
import 'package:nearsend/app/node_session.dart';
import 'package:nearsend/app/peer_session.dart';
import 'package:nearsend/core/network/task_authorization_endpoint.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/core/transfer/near_send_node.dart';
import 'package:nearsend/core/transfer/transfer_client.dart';
import 'package:nearsend/core/transfer/transfer_engine.dart';
import 'package:nearsend/features/transfer/application/file_selection_controller.dart';
import 'package:nearsend/features/transfer/application/receiving_flow.dart';
import 'package:nearsend/features/transfer/application/sending_flow.dart';
import 'package:nearsend/features/transfer/application/sending_session.dart';
import 'package:nearsend/features/transfer/application/server_receiving_flow.dart';
import 'package:nearsend/features/transfer/presentation/receive_page.dart';
import 'package:nearsend/features/transfer/presentation/send_page.dart';
import 'package:nearsend/features/transfer/presentation/transfer_pages.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';
import 'package:nearsend/platform/android_file_gateway.dart';
import 'package:nearsend/platform/ble_control_gateway.dart';

/// The application, assembled: a node with a lifetime, a connection screen showing it, and a send
/// screen that ends with bytes on the other device.
///
/// The gap this closes is not a screen - every screen existed and was tested - but a lifetime and
/// the joins between them: nothing in `lib/app/` ever opened a node, and no screen drove the sending
/// session. The last case below is the one that matters: a file chosen in the interface, sent over a
/// real TLS connection to a real second node, and compared by SHA-256 against what the receiver
/// wrote.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('nearsend-app-');
    // `TestWidgetsFlutterBinding` installs an `HttpOverrides` that answers every request with 400.
    // That is right for a widget test and wrong for the last case here, which runs two real nodes
    // over a real TLS connection: leaving it in place would make every connection fail with a
    // status nothing in this project produces.
    HttpOverrides.global = null;
  });

  tearDown(() {
    if (root.existsSync()) {
      // A failing case can leave a socket closing for a moment; the directory is scratch either way
      // and a cleanup error here would mask the assertion that failed.
      try {
        root.deleteSync(recursive: true);
      } on Object {
        // ignored on purpose
      }
    }
  });

  NodeSession session({AndroidFileGateway? gateway}) => NodeSession(
    resolveDirectory: () async => '${root.path}${Platform.pathSeparator}app',
    candidateAddresses: const <String>['127.0.0.1'],
    gateway: gateway,
  );

  /// Waits for [condition] while letting real work - a socket accepting, a hash being computed, a
  /// database handle being released - actually run.
  ///
  /// A widget test runs its body in a zone where timers are virtual, so real I/O cannot finish
  /// inside it: `runAsync` is the one place real time passes, and the pump afterwards is what lets
  /// the framework deliver the result to the code waiting on it and advance any virtual timer the
  /// code set.
  Future<void> settle(
    WidgetTester tester,
    bool Function() condition, {
    int attempts = 40,
    Duration realDelay = const Duration(milliseconds: 50),
  }) async {
    for (int attempt = 0; attempt < attempts && !condition(); attempt++) {
      await tester.runAsync(() => Future<void>.delayed(realDelay));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  bool visible(String text) => find.text(text).evaluate().isNotEmpty;

  /// Taps a control by its text, scrolling it into view first.
  ///
  /// These screens are lists and a test window is shorter than a phone, so a tap on a control below
  /// the fold lands on nothing - a fact about the test rather than about the screen.
  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.pump();
    await tester.tap(find.text(text));
    await tester.pump();
  }

  testWidgets('the connection screen shows the running node\'s own pin', (
    tester,
  ) async {
    final NodeSession node = session();
    final PeerSession peer = PeerSession();

    // Opened before the widget mounts, because opening it needs real I/O and the widget would
    // otherwise start it inside a zone where that cannot finish.
    await tester.runAsync(() => node.start());
    expect(node.phase, NodePhase.ready);

    await tester.pumpWidget(NearSendApp(session: node, peer: peer));
    await tester.pump();
    await tester.tap(find.text('发送文件'));
    await tester.pumpAndSettle();

    final String pin = node.payload!.serverFingerprint;
    expect(
      find.text(pin),
      findsOneWidget,
      reason:
          'the pin a peer must compare against has to be this device\'s real one, not a '
          'placeholder and not an empty state',
    );
    expect(
      find.text('127.0.0.1:${node.node!.server.boundPort}'),
      findsOneWidget,
      reason:
          'the published address has to name the port that is listening, or the peer is handed '
          'an address nothing answers on',
    );
    expect(
      find.textContaining('无法跨重启保留'),
      findsOneWidget,
      reason:
          'identity persistence is an open item, so a user must be told this pin will change; '
          'without that note the screen says something about their peer that is not true',
    );

    // Unmounting is what ends the application: the widget owns the session, so the node is closed
    // and the database released without any other caller having to remember to do it.
    await tester.pumpWidget(const SizedBox());
    await settle(tester, () => node.phase == NodePhase.stopped);
    expect(
      node.phase,
      NodePhase.stopped,
      reason:
          'a session handed to the application is the application\'s to close; a node left '
          'listening after the frame that owned it is gone has no owner at all',
    );
  });

  testWidgets('backgrounding turns off radar resources', (tester) async {
    final NodeSession node = session();
    final _LifecycleBleAdapter adapter = _LifecycleBleAdapter();
    final BleControlGateway ble = BleControlGateway(adapter: adapter);
    await tester.runAsync(() => node.start());

    await tester.pumpWidget(
      NearSendApp(session: node, peer: PeerSession(), bleGateway: ble),
    );
    await tester.pump();
    await tester.scrollUntilVisible(find.text('附近设备雷达'), 300);
    await tester.tap(find.byType(Switch));
    await settle(
      tester,
      () =>
          adapter.starts == 1 &&
          tester.widget<Switch>(find.byType(Switch)).value,
    );
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await settle(tester, () => adapter.session.stops == 1);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    await tester.pumpWidget(const SizedBox());
    await settle(tester, () => node.phase == NodePhase.stopped);
  });

  testWidgets('a build with no node says so rather than showing a fake pin', (
    tester,
  ) async {
    await tester.pumpWidget(const NearSendApp());
    await tester.tap(find.text('发送文件'));
    await tester.pumpAndSettle();

    expect(find.text(ConnectionPage.emptySessionNote), findsOneWidget);
  });

  testWidgets('a node that could not start states the reason', (tester) async {
    final NodeSession node = NodeSession(
      resolveDirectory: () async {
        throw const PlatformFileFailure('no application directory');
      },
      candidateAddresses: const <String>['127.0.0.1'],
    );
    await tester.pumpWidget(NearSendApp(session: node, peer: PeerSession()));
    await node.start();
    await tester.pump();

    await tester.tap(find.text('发送文件'));
    await tester.pumpAndSettle();

    expect(find.text(NodeSession.noDirectoryReason), findsOneWidget);
    expect(
      find.text(ConnectionPage.emptySessionNote),
      findsNothing,
      reason:
          '"nothing published yet" and "this device could not open its own files" are different '
          'answers, and the first would send the user looking for a fault in the other device',
    );
  });

  testWidgets(
    'a file chosen in the interface arrives at the peer, byte for byte',
    (tester) async {
      const String transferId = '11111111-2222-4333-8444-555555555555';
      const String uri = 'content://nearsend.test/e2e';

      // One chunk, and that is a deliberate limit of this case rather than of the product: a
      // widget test runs its body in a zone with virtual timers, and a multi-chunk body does not
      // finish being written inside it (observed: a 4 MiB payload stays at zero bytes at the
      // receiver however long the harness is pumped, while the same flow over the same two nodes
      // completes outside that zone). The multi-chunk, multi-megabyte path is covered by
      // `test/features/transfer/sending_flow_test.dart`, which runs the identical flow over real
      // TLS without the widget binding. What this case adds is the **wiring**: routes, the pasted
      // payload, the picker, the send action, and the figures on the screen.
      final Uint8List payload = Uint8List.fromList(<int>[
        ...List<int>.generate(4096, (int i) => i % 241),
        ...'界面发送.bin'.codeUnits,
      ]);
      final InMemoryFileGateway documents =
          InMemoryFileGateway(documents: <String, Uint8List>{uri: payload})
            ..nextPick = <PickedDocument>[
              PickedDocument(
                uri: uri,
                displayName: '界面发送.bin',
                sizeBytes: payload.length,
              ),
            ];

      // The other device: a real node, with a real listener and a real pin.
      final NearSendNode peer = (await tester.runAsync(() async {
        final NearSendNode opened = await NearSendNode.open(
          directory: '${root.path}${Platform.pathSeparator}peer',
          candidateAddresses: const <String>['127.0.0.1'],
        );
        await opened.start();
        return opened;
      }))!;
      final Directory exports = Directory(
        '${root.path}${Platform.pathSeparator}peer${Platform.pathSeparator}exports',
      );
      final PairingPayload offer = peer.openPairingSession();

      final NodeSession node = session(gateway: documents);
      await tester.runAsync(() => node.start());

      await tester.pumpWidget(
        NearSendApp(
          session: node,
          peer: PeerSession(),
          transferIdFactory: () => transferId,
        ),
      );
      await tester.pump();
      await tester.tap(find.text('发送文件'));
      await tester.pumpAndSettle();

      // The connection information the other device publishes, pasted the way a user who cannot use
      // a camera would paste it.
      await tester.enterText(find.byType(TextField), offer.encode());
      await tester.pump();
      await tapText(tester, '连接');
      await settle(tester, () => visible(ConnectionPage.connectedNote));
      expect(
        find.text(ConnectionPage.connectedNote),
        findsOneWidget,
        reason:
            'the connection is only reported as established after the peer proved the identity in '
            'that payload',
      );

      await tapText(tester, ConnectionPage.continueLabelSend);
      await tester.pumpAndSettle();
      expect(find.text(SendPage.emptyNote), findsOneWidget);

      await tapText(tester, SendPage.pickHint);
      await settle(tester, () => visible('界面发送.bin'));
      expect(
        find.text('界面发送.bin'),
        findsOneWidget,
        reason: 'the selection has to show the file the user picked, with the size the provider gave',
      );

      await tapText(tester, '发送');

      // The receiver's decision, which is the receiver's to make - so it is made here, on the other
      // node, after the offer arrives.
      await settle(tester, () {
        try {
          return peer.transfers.taskState(transferId).wireName ==
              'WAITING_ACCEPT';
        } on Object {
          return false;
        }
      }, attempts: 60);
      peer.engine.acceptLocally(
        transferId: transferId,
        context: ReceiverStorageContext(
          stagingVolume: const VolumeId('staging'),
          exportVolume: const VolumeId('internal'),
          databaseVolume: const VolumeId('internal'),
          availability: <VolumeId, VolumeAvailability>{
            const VolumeId('staging'): const VolumeAvailability.known(1 << 40),
            const VolumeId('internal'): const VolumeAvailability.known(1 << 40),
          },
          saveLocationRef: exports.path,
        ),
      );

      await settle(
        tester,
        () => visible(SendPage.phaseLabel(SendPhase.awaitingVerification)),
        attempts: 200,
        realDelay: const Duration(milliseconds: 150),
      );
      expect(
        find.text(SendPage.phaseLabel(SendPhase.awaitingVerification)),
        findsOneWidget,
        reason:
            'the screen may only report that the bytes arrived, and must not claim the transfer is '
            'finished: verifying and saving happen on the other device',
      );
      expect(
        find.text('已完成'),
        findsNothing,
        reason:
            'nothing on this screen may say 已完成, including the remaining-time figure: that word '
            'belongs to the side that verified and saved the file',
      );

      // The claim this whole case exists for: the bytes are on the receiver's disk, and they hash to
      // what the sender read. The file's identifier comes from the receiver's own row, because the
      // application generated it - the same random identifier a real run uses rather than one this
      // test chose.
      final String receivedFileId = peer.transfers.fileIds(transferId).single;
      // Inside `runAsync`: verification and export are real disk work, and the test body's zone has
      // virtual timers, so awaiting them directly would wait forever for a completion that cannot
      // be delivered there.
      final ReceivedFileOutcome outcome = (await tester.runAsync(
        () => peer.engine.finishFile(
          fileId: receivedFileId,
          targetRef: exports.path,
        ),
      ))!;
      expect(outcome.verification.wholeFileDigestMatches, isTrue);
      final File written = exports
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => !f.path.endsWith('.nearsend-part'))
          .single;
      expect(
        written.path,
        endsWith('界面发送.bin'),
        reason:
            'the name the user chose is the name the receiver writes, which is what makes the '
            'selections on the two screens describe the same file',
      );
      expect(
        sha256.convert(written.readAsBytesSync()).toString(),
        sha256.convert(payload).toString(),
        reason:
            'a UI that can connect is not a UI that can send; this is the assertion that says the '
            'file itself made it across',
      );

      await tester.pumpWidget(const SizedBox());
      await settle(tester, () => node.phase == NodePhase.stopped);
      await tester.runAsync(() async {
        await peer.stop();
        peer.close();
      });
    },
  );

  testWidgets(
    'a file the peer offers is received and saved where the user said',
    (tester) async {
      const String transferId = '33333333-4444-4555-8666-777777777777';
      const String fileId = '00000000-0000-4000-8000-000000000003';

      final Uint8List payload = Uint8List.fromList(<int>[
        ...List<int>.generate(3072, (int i) => i % 233),
        ...'界面接收.bin'.codeUnits,
      ]);

      // The other device: a real node with a real file to offer, and the same single-chunk limit as
      // the sending case above for the same reason.
      final Directory peerRoot = Directory(
        '${root.path}${Platform.pathSeparator}peer',
      );
      final File offered = File(
        '${peerRoot.path}${Platform.pathSeparator}界面接收.bin',
      );
      final NearSendNode peer = (await tester.runAsync(() async {
        await peerRoot.create(recursive: true);
        offered.writeAsBytesSync(payload);
        final NearSendNode opened = await NearSendNode.open(
          directory: peerRoot.path,
          candidateAddresses: const <String>['127.0.0.1'],
        );
        await opened.start();
        return opened;
      }))!;
      final PairingPayload offer = peer.openPairingSession();
      await tester.runAsync(
        () => peer.engine.prepareOutgoing(
          transferId: transferId,
          direction: TransferDirection.serverToClient,
          peerId: offer.sessionId,
          choices: <OutgoingFileChoice>[
            OutgoingFileChoice(
              fileId: fileId,
              relativePath: '界面接收.bin',
              path: offered.path,
            ),
          ],
        ),
      );

      final NodeSession node = session();
      await tester.runAsync(() => node.start());
      final Directory saveTo = Directory(
        '${root.path}${Platform.pathSeparator}saved',
      );

      await tester.pumpWidget(NearSendApp(session: node, peer: PeerSession()));
      await tester.pump();
      await tapText(tester, '接收文件');
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), offer.encode());
      await tester.pump();
      await tapText(tester, '连接');
      await settle(tester, () => visible(ConnectionPage.connectedNote));
      expect(find.text(ConnectionPage.connectedNote), findsOneWidget);

      await tapText(tester, ConnectionPage.continueLabelReceive);
      // Asked on a timer, so the offer shows up without the user doing anything: a few cycle of the
      // harness gives the poll its real round trip.
      await settle(
        tester,
        () => visible('1 个文件 · ${formatBytes(payload.length)}'),
        attempts: 60,
      );
      expect(
        find.text('1 个文件 · ${formatBytes(payload.length)}'),
        findsOneWidget,
        reason:
            '§6 has no push: the receiving device learns what is offered by asking, and the screen '
            'has to show what came back rather than an empty list that looks like a fault',
      );

      await tester.enterText(find.byType(TextField), saveTo.path);
      await tester.pump();
      await tapText(tester, '接收并保存');
      await settle(tester, () => visible('确认接收文件'));
      expect(find.text('确认接收文件'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '接收并保存').last);
      await tester.pump();

      await settle(
        tester,
        () => visible(ReceivePage.phaseLabel(ReceivePhase.saved)),
        attempts: 200,
        realDelay: const Duration(milliseconds: 150),
      );
      expect(
        find.text(ReceivePage.phaseLabel(ReceivePhase.saved)),
        findsOneWidget,
        reason:
            'on this side the word is earned: the whole file was verified against the frozen '
            'manifest and written where the user said',
      );
      expect(
        find.textContaining('界面接收.bin'),
        findsWidgets,
        reason:
            'the saved location names the file, which is how the user finds it',
      );

      final File written = saveTo
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => !f.path.endsWith('.nearsend-part'))
          .single;
      expect(
        sha256.convert(written.readAsBytesSync()).toString(),
        sha256.convert(payload).toString(),
        reason:
            'this is the claim the whole receiving path exists for: the file the peer offered is on '
            'this device, byte for byte, at the location the user chose',
      );
      expect(
        peer.transfers.taskState(transferId).wireName,
        'COMPLETED',
        reason:
            'the sender is told the file was saved, which is all it can know',
      );

      await tester.pumpWidget(const SizedBox());
      await settle(tester, () => node.phase == NodePhase.stopped);
      await tester.runAsync(() async {
        await peer.stop();
        peer.close();
      });
    },
  );

  testWidgets(
    'a transfer pushed to this device is accepted from the interface',
    (tester) async {
      const String fileId = '00000000-0000-4000-8000-000000000006';
      const String transferId = '66666666-7777-4888-8999-aaaaaaaaaaaa';

      final Uint8List payload = Uint8List.fromList(<int>[
        ...List<int>.generate(2048, (int i) => i % 227),
        ...'推送界面.bin'.codeUnits,
      ]);
      final File source = File('${root.path}${Platform.pathSeparator}推送界面.bin')
        ..writeAsBytesSync(payload);

      final NodeSession node = session();
      await tester.runAsync(() => node.start());
      final NearSendNode app = node.node!;

      // The other device pairs with **this** device and pushes to it. Nothing of ours has to be
      // connected for that to happen, which is the point of this path: a client that paired with this
      // node can put a file on it whether or not this end ever paired back.
      final NearSendNode peerNode = (await tester.runAsync(() async {
        final NearSendNode opened = await NearSendNode.open(
          directory: '${root.path}${Platform.pathSeparator}pusher',
          candidateAddresses: const <String>['127.0.0.1'],
        );
        await opened.start();
        return opened;
      }))!;
      final TransferClient peerToApp = (await tester.runAsync(() async {
        final TransferClient client = TransferClient(
          pin: app.pin,
          host: '127.0.0.1',
          port: app.server.boundPort,
        );
        await client.pairFrom(app.payload!, clientLabel: 'pusher');
        return client;
      }))!;

      final Directory saved = Directory(
        '${root.path}${Platform.pathSeparator}pushed',
      );

      // The push starts and stops at this device's decision, so it runs while the interface is
      // driven. Deliberately not wrapped in `runAsync`: that block may not be entered twice at once,
      // and the interface needs it too.
      final SendingFlow pusher = SendingFlow(
        session: SendingSession(engine: peerNode.engine, wire: peerToApp),
        selection: FileSelectionController(
          gateway: null,
          idFactory: () => fileId,
        ),
        now: () => 1000,
        transferIdFactory: () => transferId,
        // Nobody paired with the pushing node, so it proposes to this device rather than offering to
        // a client of its own - which is exactly the single-paste arrangement.
        ownSessionId: '99999999-9999-4999-8999-999999999999',
        peerHasPaired: () => false,
        authorizationPollInterval: const Duration(milliseconds: 50),
        authorizationTimeout: const Duration(seconds: 20),
      );
      // Selection first, in a `runAsync` of its own: reading the file length is real I/O, and it has
      // to be finished before the send starts.
      await tester.runAsync(() => pusher.addPaths(<String>[source.path]));

      int? acknowledged;
      final Future<bool> pushed = pusher.send().then((bool ok) {
        acknowledged = ok ? 1 : 0;
        return ok;
      });

      await tester.pumpWidget(NearSendApp(session: node, peer: PeerSession()));
      await tester.pump();
      await tapText(tester, '接收文件');
      await tester.pumpAndSettle();
      // The receiving screen is reached after a verified connection, although the push itself does not
      // need one: what is on offer comes from this device's own rows.
      // A **fresh** session for this device's own connection: the token the pusher used is one-time
      // and already spent, so reusing that payload would be refused - correctly.
      final PairingPayload forOurselves = app.openPairingSession();
      await tester.enterText(find.byType(TextField), forOurselves.encode());
      await tester.pump();
      await tapText(tester, '连接');
      await settle(tester, () => visible(ConnectionPage.connectedNote));
      await tapText(tester, ConnectionPage.continueLabelReceive);

      await settle(
        tester,
        () =>
            visible(ReceivePage.pushSectionHeading) &&
            visible('1 个文件 · ${formatBytes(payload.length)}'),
        attempts: 60,
      );
      expect(
        find.text(ReceivePage.pushSectionHeading),
        findsOneWidget,
        reason:
            'a push is learned from this device\'s own database, not from the peer: the client that '
            'proposed it may never be asked anything',
      );
      expect(
        find.text('1 个文件 · ${formatBytes(payload.length)}'),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextField), saved.path);
      await tester.pump();
      await settle(
        tester,
        () => visible(ReceivePage.unknownSpaceAcknowledgement),
        attempts: 120,
        realDelay: const Duration(milliseconds: 100),
      );
      await tester.scrollUntilVisible(
        find.text(ReceivePage.unknownSpaceAcknowledgement),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tapText(tester, ReceivePage.unknownSpaceAcknowledgement);
      expect(find.text(ReceivePage.spaceUnknownNote), findsOneWidget);
      await tapText(tester, '接收并保存');
      await settle(tester, () => visible('确认接收文件'));
      expect(find.text('确认接收文件'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '接收并保存').last);
      await tester.pumpAndSettle();
      expect(find.text('无法确认剩余空间'), findsOneWidget);
      await tapText(tester, '仍然接收');

      await settle(
        tester,
        () => visible(ReceivePage.pushPhaseLabel(ServerReceivePhase.saved)),
        attempts: 200,
        realDelay: const Duration(milliseconds: 150),
      );
      expect(
        find.text(ReceivePage.pushPhaseLabel(ServerReceivePhase.saved)),
        findsWidgets,
      );
      // The sender finishes on its own schedule; waited for rather than assumed, so a failure there
      // is reported here instead of as a missing file below.
      await settle(tester, () => acknowledged != null, attempts: 60);
      expect(
        acknowledged,
        isNotNull,
        reason: 'the pushing side has to learn that this device took the file',
      );
      await pushed;

      final File written = saved
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => !f.path.endsWith('.nearsend-part'))
          .single;
      expect(
        sha256.convert(written.readAsBytesSync()).toString(),
        sha256.convert(payload).toString(),
        reason:
            'the pushed direction is the one that works with a single paste, and this is the '
            'assertion that a file put on this device through it is the file that was sent',
      );

      await tester.pumpWidget(const SizedBox());
      await settle(tester, () => node.phase == NodePhase.stopped);
      await tester.runAsync(() async {
        peerToApp.close();
        await peerNode.stop();
        peerNode.close();
      });
    },
  );
}

class _LifecycleBleAdapter implements BlePlatformAdapter {
  final _LifecycleBleSession session = _LifecycleBleSession();
  int starts = 0;

  @override
  Future<bool> requestAuthorization() async => true;

  @override
  Future<BlePlatformSession> start(BlePublication publication) async {
    starts++;
    return session;
  }
}

class _LifecycleBleSession implements BlePlatformSession {
  final StreamController<BlePlatformEvent> _events =
      StreamController<BlePlatformEvent>.broadcast();
  int stops = 0;

  @override
  Stream<BlePlatformEvent> get events => _events.stream;

  @override
  Future<void> connect(String peerId) async {}

  @override
  Future<int> maximumFrameBytes(String peerId) async => 20;

  @override
  Future<void> sendFrame(String peerId, Uint8List frame) async {}

  @override
  Future<void> stop() async {
    stops++;
  }
}
