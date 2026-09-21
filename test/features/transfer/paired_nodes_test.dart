import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/storage/source_bytes.dart';
import 'package:nearsend/core/transfer/near_send_node.dart';
import 'package:nearsend/core/transfer/transfer_client.dart';
import 'package:nearsend/features/transfer/application/file_selection_controller.dart';
import 'package:nearsend/features/transfer/application/receiving_flow.dart';
import 'package:nearsend/features/transfer/application/sending_flow.dart';
import 'package:nearsend/features/transfer/application/sending_session.dart';

/// Two nodes exchanging a file with **nothing but production flows on both ends**.
///
/// ## Why this test exists
///
/// Every earlier end-to-end case drove one side by hand: the sending case called the receiver's
/// `acceptLocally` from the test, and the receiving case prepared the offer from the test. Both
/// proved a half. This one runs the whole exchange the way the application does it - one flow
/// offering, another answering - which is the only arrangement in which "两台设备之间能否互传"
/// is actually the question being asked.
///
/// ## Why the sender offers instead of pushing
///
/// A push is a client's move: the peer must accept it as a **server**, and this build has no screen
/// for that. An offer is a server's move that the peer finds through `GET /v1/offers` - and the
/// receiving screen answers exactly that. So the sending flow offers whenever the peer has paired
/// with this device, and these cases pin that choice, including the fact that it is *asked for* at
/// send time rather than assumed.
void main() {
  late Directory root;
  late NearSendNode host;
  late NearSendNode guest;
  late TransferClient guestToHost;
  late Directory received;

  const String fileId = '00000000-0000-4000-8000-000000000004';
  const String transferId = '44444444-5555-4666-8777-888888888888';

  final Uint8List payload = Uint8List.fromList(<int>[
    ...List<int>.generate(
      ProtocolLimits.chunkSizeBytes + 2048,
      (int i) => i % 211,
    ),
    ...'互传.bin'.codeUnits,
  ]);

  setUp(() async {
    root = Directory.systemTemp.createTempSync('nearsend-pair-');
    received = Directory('${root.path}${Platform.pathSeparator}received');

    SourceBytes resolve(String ref, int size) => FileSourceBytes(File(ref));

    // The host is the node whose payload the guest pastes: it is the server in this relationship.
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
      // A failing case can leave a flow mid-step for a moment; the directory is scratch either way
      // and a cleanup error here would mask the assertion that failed.
      try {
        root.deleteSync(recursive: true);
      } on Object {
        // ignored on purpose
      }
    }
  });

  /// Waits for [condition] while real I/O runs, so a case does not depend on how long a hash takes
  /// on the machine it happens to run on.
  Future<void> waitUntil(bool Function() condition) async {
    final Stopwatch waited = Stopwatch()..start();
    while (!condition() && waited.elapsed < const Duration(seconds: 20)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// A real file for the host to offer.
  File sourceFile() =>
      File('${root.path}${Platform.pathSeparator}互传.bin')
        ..writeAsBytesSync(payload);

  /// The host's sending flow, set up the way the application sets it up.
  SendingFlow hostFlow({required String sessionId}) {
    final FileSelectionController selection = FileSelectionController(
      gateway: null,
      idFactory: () => fileId,
    );
    return SendingFlow(
      session: SendingSession(engine: host.engine, wire: guestToHost),
      selection: selection,
      now: () => 1000,
      transferIdFactory: () => transferId,
      ownSessionId: sessionId,
      mirror: host.mirror,
      // The question the application asks, asked the same way: has the guest actually paired with
      // the session this device published?
      peerHasPaired: () => host.pairing.hasPairedClient(sessionId),
      peerFetchInterval: const Duration(milliseconds: 25),
      peerFetchTimeout: const Duration(seconds: 20),
    );
  }

  test('the guest pairing with the host is what the host asks about', () async {
    expect(
      host.pairing.hasPairedClient(host.payload!.sessionId),
      isTrue,
      reason:
          'the guest pasted this payload, so a transfer the host offers as a server is visible to '
          'it; a getter that said otherwise would send the host down the pushing path instead',
    );
    expect(
      host.pairing.hasPairedClient('99999999-9999-4999-8999-999999999999'),
      isFalse,
      reason: 'a session nobody paired with is not a client',
    );
  });

  test(
    'a file offered by one node is received and saved by the other',
    () async {
      final SendingFlow sending = hostFlow(sessionId: host.payload!.sessionId);
      await sending.addPaths(<String>[sourceFile().path]);
      expect(sending.phase, SendPhase.ready);

      final ReceivingFlow receiving = ReceivingFlow(
        engine: guest.engine,
        wire: guestToHost,
        now: () => 1000,
      );

      // Both ends move at once, exactly as two devices would: the host offers and then waits, and the
      // guest asks what is on offer.
      final Future<bool> offered = sending.send();
      await waitUntil(() => sending.phase == SendPhase.offeredToPeer);

      expect(
        sending.phase,
        SendPhase.offeredToPeer,
        reason:
            'the host is the server here: §6 has no push, so it lists the offer and the next move '
            'belongs to the guest',
      );
      expect(sending.mode, SendMode.offer);

      final List<OfferSummary> offers = await receiving.refresh();
      expect(
        offers.map((OfferSummary o) => o.transferId),
        contains(transferId),
        reason: 'the offer is visible to the session that paired with the host',
      );
      expect(offers.single.totalBytes, payload.length);

      expect(
        await receiving.accept(offers.single, saveLocationRef: received.path),
        isTrue,
      );
      expect(receiving.phase, ReceivePhase.saved);

      expect(await offered, isTrue);
      expect(
        sending.phase,
        SendPhase.savedByPeer,
        reason:
            'the guest reported that it verified and saved the file through §10, so on this side the '
            'word is earned rather than assumed - which is the state the pushing path deliberately '
            'cannot reach',
      );
      expect(
        sending.progress!.transferredBytes,
        payload.length,
        reason: 'the figure came from §9s mirror, which is the only progress a server sender can have',
      );

      final File written = received
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => !f.path.endsWith('.nearsend-part'))
          .single;
      expect(
        sha256.convert(written.readAsBytesSync()).toString(),
        sha256.convert(payload).toString(),
        reason:
            'this is the assertion the whole milestone rests on: two nodes, two production flows, '
            'and the same bytes at the far end',
      );
    },
  );

  test(
    'without a paired client the sender pushes instead of waiting forever',
    () async {
      // Nobody paired with this session, so an offer would be invisible to the other end and this
      // device would sit in 等待对方取走 until it timed out. The mode has to follow what the other end
      // can actually observe.
      //
      // The pushing side is the **guest**, because that is what a push is: this device is a client of
      // the node it sends to, so its own engine plans and its wire proposes.
      final SendingFlow sending = SendingFlow(
        session: SendingSession(engine: guest.engine, wire: guestToHost),
        selection: FileSelectionController(
          gateway: null,
          idFactory: () => fileId,
        ),
        now: () => 1000,
        transferIdFactory: () => transferId,
        ownSessionId: '99999999-9999-4999-8999-999999999999',
        peerHasPaired: () => host.pairing.hasPairedClient(
          '99999999-9999-4999-8999-999999999999',
        ),
        // Short, because the property under test is that the wait is bounded and says why - not how
        // long the default bound is.
        authorizationTimeout: const Duration(milliseconds: 600),
        authorizationPollInterval: const Duration(milliseconds: 25),
      );
      await sending.addPaths(<String>[sourceFile().path]);

      final Future<bool> pushed = sending.send();
      await waitUntil(() => sending.phase != SendPhase.preparing);

      expect(
        sending.mode,
        SendMode.push,
        reason:
            'an offer nobody can see is not a transfer; the mode is decided by what the other end is '
            'able to observe',
      );
      expect(
        sending.phase,
        SendPhase.waitingForPeer,
        reason: 'and this device must be waiting for the peer decision, not for a puller',
      );

      // Nobody accepts on the other side, so the push ends in its bounded refusal rather than hanging.
      expect(await pushed, isFalse);
      expect(sending.phase, SendPhase.failed);
      expect(sending.failureReason, contains('超时'));
    },
  );
}
