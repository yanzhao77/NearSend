import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:nearsend/platform/platform_permission_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/app.dart';
import 'package:nearsend/app/application/radar_controller.dart';
import 'package:nearsend/app/node_session.dart';
import 'package:nearsend/app/peer_session.dart';
import 'package:nearsend/core/network/task_authorization_endpoint.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/core/transfer/near_send_node.dart';
import 'package:nearsend/core/transfer/transfer_client.dart';
import 'package:nearsend/core/transfer/transfer_engine.dart';
import 'package:nearsend/features/transfer/application/file_selection_controller.dart';
import 'package:nearsend/features/transfer/application/sending_flow.dart';
import 'package:nearsend/features/transfer/application/sending_session.dart';
import 'package:nearsend/features/transfer/presentation/receive_page.dart';
import 'package:nearsend/features/transfer/presentation/send_page.dart';
import 'package:nearsend/features/pairing/presentation/pairing_qr_widgets.dart';
import 'package:nearsend/features/pairing/presentation/connection_surfaces.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';
import 'package:nearsend/features/tasks/presentation/task_overview_page.dart';
import 'package:nearsend/app/presentation/app_shell.dart';
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

  String taskSnapshot(WidgetTester tester) {
    final controller = tester
        .widget<TaskOverviewPage>(find.byType(TaskOverviewPage))
        .controller;
    return 'error=${controller.error}, tasks=${[for (final task in controller.tasks) '${task.taskId}: ${task.state}/${task.status}, '
          '${task.committedBytes}/${task.totalBytes}, '
          'observed=${task.observedSentBytes}']}';
  }

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

  testWidgets('home scanner pairs over real TLS without a connection form', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final node = session();
    final peer = PeerSession();
    NearSendNode? remote;
    try {
      remote = await tester.runAsync(() async {
        final value = await NearSendNode.open(
          directory: '${root.path}${Platform.pathSeparator}scanner-peer',
          candidateAddresses: const ['127.0.0.1'],
          deviceName: '真实扫码对端',
        );
        await value.start();
        value.openPairingSession();
        return value;
      });
      await tester.runAsync(() => node.start());
      int scannerBuilds = 0;
      await tester.pumpWidget(
        NearSendApp(
          session: node,
          peer: peer,
          permissionGateway: _GrantedPermission(),
          cameraScannerPageBuilder: (_) {
            scannerBuilds++;
            return Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () =>
                      Navigator.of(context).pop(remote!.payload!.encode()),
                  child: const Text('返回已扫描载荷'),
                ),
              ),
            );
          },
        ),
      );
      await tester.ensureVisible(find.text('扫一扫连接设备'));
      tester
          .widget<NearSendAppShell>(find.byType(NearSendAppShell))
          .onRadarDevicePressed!(
        const RadarDevice(
          id: 'unverified-candidate',
          name: '未验证的发现名称',
          detail: '候选',
          isKnown: false,
          isReady: false,
          isRevoked: false,
          discoveryMethod: '蓝牙发现',
        ),
      );
      tester
          .widget<NearSendAppShell>(find.byType(NearSendAppShell))
          .onRadarDevicePressed!(
        const RadarDevice(
          id: 'unverified-candidate',
          name: '未验证的发现名称',
          detail: '候选',
          isKnown: false,
          isReady: false,
          isRevoked: false,
          discoveryMethod: '蓝牙发现',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('蓝牙用于发现设备'), findsOneWidget);
      expect(peer.isConnected, isFalse);
      expect(scannerBuilds, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      final scan = tester
          .widget<NearSendAppShell>(find.byType(NearSendAppShell))
          .onScanPairing!;
      scan();
      scan();
      await tester.pumpAndSettle();
      expect(scannerBuilds, 1);
      await tester.tap(find.text('返回已扫描载荷'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester, () => peer.isConnected);
      expect(peer.isConnected, isTrue, reason: peer.failureReason);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(AdvancedConnectionPage), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('真实扫码对端'), findsOneWidget);
      expect(find.text('未验证的发现名称'), findsNothing);
      expect(
        remote!.pairing.hasPairedClient(remote.payload!.sessionId),
        isTrue,
      );
    } finally {
      await tester.pumpWidget(const SizedBox());
      await settle(tester, () => node.phase == NodePhase.stopped);
      await tester.runAsync(() async {
        await remote?.stop();
        remote?.close();
      });
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('local QR pairing appears on home without discovery enabled', (
    tester,
  ) async {
    final node = session();
    await tester.runAsync(() => node.start());
    await tester.pumpWidget(NearSendApp(session: node, peer: PeerSession()));
    await tester.pump();
    await tester.tap(find.text('本机设备'));
    await tester.pumpAndSettle();
    expect(find.text('我的连接二维码'), findsOneWidget);
    final payload = node.payload!;
    final client = TransferClient(
      pin: payload.serverFingerprint,
      host: '127.0.0.1',
      port: node.node!.server.boundPort,
    );
    await tester.runAsync(() => client.pairFrom(payload, clientLabel: '扫码手机'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('设备已连接'), findsOneWidget);
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('扫码手机'), findsOneWidget);
    expect(find.text('已连接 · 二维码配对 · 本次会话'), findsOneWidget);
    await tester.tap(find.text('扫码手机'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('设备连接'), findsOneWidget);
    expect(find.text('断开连接'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(node.node!.pairing.hasPairedClient(payload.sessionId), isTrue);
    final otherPayload = node.node!.openPairingSession();
    final otherClient = TransferClient(
      pin: otherPayload.serverFingerprint,
      host: '127.0.0.1',
      port: node.node!.server.boundPort,
    );
    await tester.runAsync(
      () => otherClient.pairFrom(otherPayload, clientLabel: '另一台手机'),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(node.node!.pairing.hasPairedClient(otherPayload.sessionId), isTrue);
    await tester.tap(find.text('扫码手机'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('断开连接'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(node.node!.pairing.hasPairedClient(payload.sessionId), isFalse);
    expect(node.phase, NodePhase.ready);
    expect(node.node!.pairing.hasPairedClient(otherPayload.sessionId), isTrue);
    expect(find.text('另一台手机'), findsOneWidget);
    expect(find.text('扫码手机'), findsNothing);
    otherClient.close();
    client.close();
    await tester.pumpWidget(const SizedBox());
    await settle(tester, () => node.phase == NodePhase.stopped);
  });

  testWidgets('local QR uses the live invitation without refreshing on open', (
    tester,
  ) async {
    final node = session();
    await tester.runAsync(() => node.start());
    final payload = node.payload!;
    await tester.pumpWidget(NearSendApp(session: node, peer: PeerSession()));
    await tester.tap(find.text('本机设备'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<PairingQrView>(find.byType(PairingQrView)).payload,
      payload.encode(),
    );
    expect(node.payload, same(payload));
    expect(find.byType(TextField), findsNothing);
    await tester.pageBack();
    await tester.pump();
    expect(node.phase, NodePhase.ready);
    await tester.pumpWidget(const SizedBox());
    await settle(tester, () => node.phase == NodePhase.stopped);
  });

  testWidgets('backgrounding turns off Bluetooth resources', (tester) async {
    final NodeSession node = session();
    final _LifecycleBleAdapter adapter = _LifecycleBleAdapter();
    final BleControlGateway ble = BleControlGateway(adapter: adapter);
    await tester.runAsync(() => node.start());

    await tester.pumpWidget(
      NearSendApp(session: node, peer: PeerSession(), bleGateway: ble),
    );
    await tester.pump();
    final Finder bluetoothSwitch = find.byKey(
      const ValueKey<String>('bluetooth-discovery-switch'),
    );
    await tester.scrollUntilVisible(bluetoothSwitch, 300);
    await tester.tap(bluetoothSwitch);
    await settle(
      tester,
      () =>
          adapter.starts == 1 &&
          tester.widget<SwitchListTile>(bluetoothSwitch).value,
    );
    expect(tester.widget<SwitchListTile>(bluetoothSwitch).value, isTrue);
    expect(adapter.publication?.displayName, 'NearSend');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(adapter.session.stops, 0);
    expect(tester.widget<SwitchListTile>(bluetoothSwitch).value, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await settle(tester, () => adapter.session.stops == 1);
    expect(tester.widget<SwitchListTile>(bluetoothSwitch).value, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    await tester.pumpWidget(const SizedBox());
    await settle(tester, () => node.phase == NodePhase.stopped);
  });

  testWidgets(
    'sending without a connected device shows a dialog, not local info',
    (tester) async {
      await tester.pumpWidget(const NearSendApp());
      await tester.tap(find.text('传输'));
      await tester.pump();
      await tester.tap(find.text('发送文件'));
      await tester.pumpAndSettle();

      expect(find.text('目前没有设备连接'), findsOneWidget);
      expect(find.text('本机连接信息'), findsNothing);
      expect(find.text('本机尚未开启配对会话，因此还没有可出示的连接信息。'), findsNothing);
    },
  );

  testWidgets('receiving opens receive page without connection information', (
    tester,
  ) async {
    await tester.pumpWidget(const NearSendApp());
    await tester.tap(find.text('传输'));
    await tester.pump();
    await tester.tap(find.text('接收文件'));
    await tester.pumpAndSettle();

    expect(find.text('本机节点尚未就绪，无法接收。'), findsOneWidget);
    expect(find.text('本机连接信息'), findsNothing);
    expect(find.text('本机尚未开启配对会话，因此还没有可出示的连接信息。'), findsNothing);
  });

  testWidgets('advanced connection is separate and has no local invitation', (
    tester,
  ) async {
    await tester.pumpWidget(const NearSendApp());
    Navigator.of(tester.element(find.byType(NearSendAppShell)))
        .pushNamed(NearSendApp.advancedConnectionRoute);
    await tester.pumpAndSettle();
    expect(find.text('高级连接'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(PairingQrView), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('首页'), findsWidgets);
  });

  testWidgets(
    'sending after node startup failure still hides connection info',
    (tester) async {
      final NodeSession node = NodeSession(
        resolveDirectory: () async {
          throw const PlatformFileFailure('no application directory');
        },
        candidateAddresses: const <String>['127.0.0.1'],
      );
      await tester.pumpWidget(NearSendApp(session: node, peer: PeerSession()));
      await node.start();
      await tester.pump();

      await tester.tap(find.text('传输'));
      await tester.pump();
      await tester.tap(find.text('发送文件'));
      await tester.pumpAndSettle();

      expect(find.text('目前没有设备连接'), findsOneWidget);
      expect(find.text(NodeSession.noDirectoryReason), findsNothing);
      expect(find.text('本机连接信息'), findsNothing);
    },
  );

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
      Navigator.of(tester.element(find.byType(NearSendAppShell)))
          .pushNamed(NearSendApp.advancedConnectionRoute);
      await tester.pumpAndSettle();

      // The connection information the other device publishes, pasted the way a user who cannot use
      // a camera would paste it.
      await tester.enterText(find.byType(TextField), offer.encode());
      await tester.pump();
      await tapText(tester, '连接');
      await settle(
        tester,
        () => find.byType(AdvancedConnectionPage).evaluate().isEmpty,
      );
      expect(find.byType(AdvancedConnectionPage), findsNothing);
      await tapText(tester, '传输');
      await tapText(tester, '发送文件');
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
      await settle(tester, () => visible('任务'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('任务'), findsOneWidget);
      expect(find.text(transferId), findsOneWidget);
      expect(find.byType(SendPage), findsNothing);
      // The sender's own authenticated client polls the peer for server offers too.
      // Its just-proposed client_to_server task must not be echoed back as a receive
      // prompt while the actual receiver is waiting for its local decision.
      await tester.pump(const Duration(seconds: 2));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(
        find.text('收到文件'),
        findsNothing,
        reason:
            'the sender must not be prompted to accept its own outgoing file',
      );
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
      peer.transfers.transitionTask(
        taskId: transferId,
        to: TransferState.transferring,
      );

      await settle(
        tester,
        () {
          try {
            return peer.tasks.committedBytesForTask(transferId) ==
                payload.length;
          } on Object {
            return false;
          }
        },
        attempts: 200,
        realDelay: const Duration(milliseconds: 150),
      );
      await settle(
        tester,
        () => visible('对端进度 ${payload.length} / ${payload.length} B'),
        attempts: 100,
      );
      expect(
        find.text('对端进度 ${payload.length} / ${payload.length} B'),
        findsOneWidget,
        reason: taskSnapshot(tester),
      );
      expect(
        find.text('已完成'),
        findsNothing,
        reason:
            'the sender may not say 已完成 until receiver verification and saving; that word '
            'belongs to the side that verified and saved the file',
      );

      // The claim this whole case exists for: the bytes are on the receiver's disk, and they hash to
      // what the sender read. The file's identifier comes from the receiver's own row, because the
      // application generated it - the same random identifier a real run uses rather than one this
      // test chose.
      final String receivedFileId = peer.transfers.fileIds(transferId).single;
      // Inside `runAsync`: verification and export are real disk work, while the test body's zone
      // virtualizes the sender's status-poll timer.
      peer.transfers.transitionTask(
        taskId: transferId,
        to: TransferState.verifying,
      );
      final ReceivedFileOutcome outcome = (await tester.runAsync(
        () => peer.engine.finishFile(
          fileId: receivedFileId,
          targetRef: exports.path,
        ),
      ))!;
      expect(outcome.verification.wholeFileDigestMatches, isTrue);
      peer.transfers.transitionTask(
        taskId: transferId,
        to: TransferState.exporting,
      );
      peer.transfers.transitionTask(
        taskId: transferId,
        to: TransferState.completed,
      );
      await settle(
        tester,
        () => visible('已完成'),
        realDelay: const Duration(milliseconds: 100),
      );
      expect(find.text('已完成'), findsWidgets);
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
      Navigator.of(tester.element(find.byType(NearSendAppShell)))
          .pushNamed(NearSendApp.advancedConnectionRoute);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), offer.encode());
      await tester.pump();
      await tapText(tester, '连接');
      await settle(
        tester,
        () => find.byType(AdvancedConnectionPage).evaluate().isEmpty,
      );
      expect(find.byType(AdvancedConnectionPage), findsNothing);

      // The app-level inbox surfaces the peer's offer while this device is still on the connection
      // screen; accepting the prompt then opens the existing save-location confirmation.
      await settle(
        tester,
        () => visible('收到文件') && visible('界面接收.bin'),
        attempts: 60,
      );
      expect(
        find.text('收到文件'),
        findsOneWidget,
        reason: 'the connected receiver must be prompted independently of its current route',
      );
      await tapText(tester, '接收');
      await tester.pumpAndSettle();
      expect(
        find.text('1 个文件 · ${formatBytes(payload.length)}'),
        findsOneWidget,
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
        () {
          try {
            return node.node!.transfers.taskState(transferId) ==
                TransferState.completed;
          } on Object {
            return false;
          }
        },
        attempts: 200,
        realDelay: const Duration(milliseconds: 150),
      );
      await settle(tester, () => visible('已完成'));
      expect(find.text('任务'), findsOneWidget);
      expect(
        find.text('已完成'),
        findsOneWidget,
        reason:
            'on this side the word is earned: the whole file was verified against the frozen '
            'manifest and written where the user said; ${taskSnapshot(tester)}',
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
      // The offer is surfaced above the home screen; the receiver need not open the receive page.
      await settle(
        tester,
        () => visible('收到文件') && visible('推送界面.bin'),
        attempts: 60,
      );
      expect(
        find.text('收到文件'),
        findsOneWidget,
        reason: 'the app-level inbox must prompt while the receiver is still on its home screen',
      );
      expect(find.text('推送界面.bin'), findsOneWidget);
      await tapText(tester, '接收');
      await tester.pumpAndSettle();
      expect(find.text(ReceivePage.pushSectionHeading), findsOneWidget);
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
        () => app.transfers.taskState(transferId) == TransferState.completed,
        attempts: 200,
        realDelay: const Duration(milliseconds: 150),
      );
      await settle(tester, () => visible('已完成'));
      expect(find.text('任务'), findsOneWidget);
      expect(find.text('已完成'), findsOneWidget);
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
  BlePublication? publication;

  @override
  Future<bool> requestAuthorization() async => true;

  @override
  Future<BlePlatformSession> start(BlePublication publication) async {
    starts++;
    this.publication = publication;
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

class _GrantedPermission implements PlatformPermissionGateway {
  @override
  Future<PlatformPermissionState> check(
    PlatformPermissionKind permission,
  ) async => PlatformPermissionState.granted;
  @override
  Future<PlatformPermissionState> request(
    PlatformPermissionKind permission,
  ) async => PlatformPermissionState.granted;
}
