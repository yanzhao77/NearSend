import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/network/task_authorization_endpoint.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/storage/source_bytes.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/core/transfer/near_send_node.dart';
import 'package:nearsend/core/transfer/transfer_client.dart';
import 'package:nearsend/features/transfer/application/file_selection_controller.dart';
import 'package:nearsend/features/transfer/application/sending_flow.dart';
import 'package:nearsend/features/transfer/application/sending_session.dart';
import 'package:nearsend/features/transfer/application/server_receiving_flow.dart';

/// A **push** finishing on the side that was asked to accept it.
///
/// ## What this covers that nothing else did
///
/// The offering path is a server's move and works when both devices have paired with each other.
/// This is the other one: a client proposes a transfer *to a server*, and the server is the
/// receiver. It is the direction that works with a **single** paste - the device whose information
/// was pasted accepts, and the device that pasted pushes - and until now it had no flow at all, so
/// "只粘贴一侧也能传" was not true in either direction.
///
/// Both ends here are production code: `SendingFlow` in its pushing mode and
/// [ServerReceivingFlow] on the other node. Nothing is accepted or finalised from the test.
void main() {
  late Directory root;
  late NearSendNode host;
  late NearSendNode guest;
  late TransferClient guestToHost;
  late Directory saved;

  const String fileId = '00000000-0000-4000-8000-000000000005';
  const String transferId = '55555555-6666-4777-8888-999999999999';

  final Uint8List payload = Uint8List.fromList(<int>[
    ...List<int>.generate(
      ProtocolLimits.chunkSizeBytes + 1024,
      (int i) => i % 223,
    ),
    ...'推送接收.bin'.codeUnits,
  ]);

  setUp(() async {
    root = Directory.systemTemp.createTempSync('nearsend-push-');
    saved = Directory('${root.path}${Platform.pathSeparator}saved');

    SourceBytes resolve(String ref, int size) => FileSourceBytes(File(ref));

    // The host is the server: the guest pasted its connection information, so the guest is its
    // client and pushes to it.
    host = await NearSendNode.open(
      directory: '${root.path}${Platform.pathSeparator}host',
      candidateAddresses: const <String>['127.0.0.1'],
      sourceResolver: resolve,
    );
    await host.start();
    guest = await NearSendNode.open(
      directory: '${root.path}${Platform.pathSeparator}guest',
      candidateAddresses: const <String>['127.0.0.1'],
      sourceResolver: resolve,
    );
    await guest.start();

    final PairingPayload published = host.openPairingSession();
    guestToHost = TransferClient(
      pin: published.serverFingerprint,
      host: '127.0.0.1',
      port: host.server.boundPort,
    );
    await guestToHost.pairFrom(published, clientLabel: 'guest');
  });

  tearDown(() async {
    guestToHost.close();
    await host.stop();
    host.close();
    guest.close();
    if (root.existsSync()) {
      try {
        root.deleteSync(recursive: true);
      } on Object {
        // A failing case can leave work in flight for a moment; the directory is scratch.
      }
    }
  });

  Future<void> waitUntil(bool Function() condition) async {
    final Stopwatch waited = Stopwatch()..start();
    while (!condition() && waited.elapsed < const Duration(seconds: 20)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Asks the server's own rows until they show an offer, or the bound runs out.
  ///
  /// The list is only filled by asking, so a wait that did not ask would always run to its bound -
  /// a slow test pretending to be a patient one.
  Future<void> waitForOffer(ServerReceivingFlow flow) async {
    final Stopwatch waited = Stopwatch()..start();
    while (waited.elapsed < const Duration(seconds: 20)) {
      await flow.refresh();
      if (flow.pending.isNotEmpty) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  File sourceFile() =>
      File('${root.path}${Platform.pathSeparator}推送接收.bin')
        ..writeAsBytesSync(payload);

  /// The guest's sending flow, in the arrangement the application uses when nobody paired with it:
  /// its own engine plans, and its client proposes to the host.
  SendingFlow guestFlow() => SendingFlow(
    session: SendingSession(engine: guest.engine, wire: guestToHost),
    selection: FileSelectionController(gateway: null, idFactory: () => fileId),
    now: () => 1000,
    transferIdFactory: () => transferId,
    ownSessionId: '99999999-9999-4999-8999-999999999999',
    peerHasPaired: () => false,
    authorizationPollInterval: const Duration(milliseconds: 25),
    authorizationTimeout: const Duration(seconds: 20),
  );

  /// The free space the caller measured. Stated here rather than measured because this layer must
  /// never invent a space figure, and a test is the one place where stating it is honest.
  ReceiverStorageContext context() => ReceiverStorageContext(
    stagingVolume: const VolumeId('staging'),
    exportVolume: const VolumeId('internal'),
    databaseVolume: const VolumeId('internal'),
    availability: <VolumeId, VolumeAvailability>{
      const VolumeId('staging'): const VolumeAvailability.known(1 << 40),
      const VolumeId('internal'): const VolumeAvailability.known(1 << 40),
    },
    saveLocationRef: saved.path,
  );

  test('a client push is accepted, received and saved by the server', () async {
    final SendingFlow sending = guestFlow();
    await sending.addPaths(<String>[sourceFile().path]);
    expect(sending.phase, SendPhase.ready);

    final ServerReceivingFlow receiving = ServerReceivingFlow(
      engine: host.engine,
      now: () => 1000,
      commitPollInterval: const Duration(milliseconds: 25),
    );

    // The push starts and stops at the peer's decision; the server learns about it by asking its own
    // rows, which is the only way its user could ever be shown the offer.
    final Future<bool> pushed = sending.send();
    await waitForOffer(receiving);
    // The seal is what makes an offer an offer, and the sending side enters its waiting phase
    // immediately after it - so by the time this device can see the offer, that side is waiting.
    // Allowing a moment for that keeps the assertion about the fact rather than about scheduling.
    await waitUntil(() => sending.phase == SendPhase.waitingForPeer);

    expect(
      receiving.pending.map((ServerOffer o) => o.transferId),
      contains(transferId),
      reason:
          'a client proposed this transfer to this node, so §6 makes its acceptance this node\'s '
          'decision - and the row is already in this node\'s own database',
    );
    expect(sending.phase, SendPhase.waitingForPeer);

    final Future<bool> received = receiving.accept(
      receiving.pending.single,
      context: context(),
      targetRef: saved.path,
    );

    expect(await pushed, isTrue);
    expect(
      sending.phase,
      SendPhase.awaitingVerification,
      reason:
          'the pushing side knows the bytes arrived and nothing more: verifying and saving are the '
          'receiver\'s work, and in this direction the receiver is the other node',
    );

    expect(await received, isTrue);
    expect(receiving.phase, ServerReceivePhase.saved);
    expect(receiving.savedPaths, hasLength(1));

    final File written = saved
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => !f.path.endsWith('.nearsend-part'))
        .single;
    expect(
      sha256.convert(written.readAsBytesSync()).toString(),
      sha256.convert(payload).toString(),
      reason:
          'this is the claim the pushing direction exists for: a client that pasted this device\'s '
          'connection information can put a file on it, byte for byte',
    );
  });

  test('an offer stops being offered once it has been answered', () async {
    final SendingFlow sending = guestFlow();
    await sending.addPaths(<String>[sourceFile().path]);
    final ServerReceivingFlow receiving = ServerReceivingFlow(
      engine: host.engine,
      now: () => 1000,
      commitPollInterval: const Duration(milliseconds: 25),
    );

    final Future<bool> pushed = sending.send();
    await waitForOffer(receiving);
    expect(receiving.pending, hasLength(1));

    expect(
      await receiving.accept(
        receiving.pending.single,
        context: context(),
        targetRef: saved.path,
      ),
      isTrue,
    );
    expect(await pushed, isTrue);

    await receiving.refresh();
    expect(
      receiving.pending,
      isEmpty,
      reason:
          'a transfer that has been accepted is no longer waiting for an answer; leaving it in the '
          'list would offer the user a decision they already made',
    );
    expect(
      receiving.phase,
      ServerReceivePhase.saved,
      reason:
          'and asking again must not walk a finished receive backwards into deciding - the screen '
          'would lose the result it is showing',
    );
  });
}
