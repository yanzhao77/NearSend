import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/storage/export_naming.dart';
import 'package:nearsend/core/storage/receive_output_plan_repository.dart';
import 'package:nearsend/core/storage/source_bytes.dart';
import 'package:nearsend/core/transfer/near_send_node.dart';
import 'package:nearsend/core/transfer/transfer_client.dart';
import 'package:nearsend/core/transfer/transfer_engine.dart';
import 'package:nearsend/features/transfer/application/receiving_flow.dart';

/// The receiving flow, against a real server offering a real file over real TLS.
///
/// The claims worth pinning are about **order and authority**: chunks are committed through this
/// device's own rows before the next is asked for, what is asked for comes from those rows rather
/// than from a counter, and a file reaches the target directory only after its whole-file digest
/// matched the frozen manifest.
void main() {
  late Directory root;
  late NearSendNode server;
  late NearSendNode client;
  late TransferClient wire;

  const String transferId = '22222222-3333-4444-8555-666666666666';
  const String fileId = '00000000-0000-4000-8000-000000000002';

  final Uint8List payload = Uint8List.fromList(<int>[
    ...List<int>.generate(
      ProtocolLimits.chunkSizeBytes + 1234,
      (int i) => i % 197,
    ),
    ...'接收流程.bin'.codeUnits,
  ]);

  setUp(() async {
    root = Directory.systemTemp.createTempSync('nearsend-recv-');

    SourceBytes resolve(String ref, int size) => FileSourceBytes(File(ref));

    server = await NearSendNode.open(
      directory: '${root.path}${Platform.pathSeparator}server',
      candidateAddresses: const <String>['127.0.0.1'],
      sourceResolver: resolve,
    );
    await server.start();
    client = await NearSendNode.open(
      directory: '${root.path}${Platform.pathSeparator}client',
      candidateAddresses: const <String>['127.0.0.1'],
      sourceResolver: resolve,
    );

    final PairingPayload pairingPayload = server.openPairingSession();
    wire = TransferClient(
      pin: pairingPayload.serverFingerprint,
      host: '127.0.0.1',
      port: server.server.boundPort,
    );
    await wire.pairFrom(pairingPayload, clientLabel: 'receive-test');
  });

  tearDown(() async {
    wire.close();
    await server.stop();
    server.close();
    client.close();
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  /// A real file on disk for the sender to read, so the offer describes bytes rather than a name.
  File offeredFile() =>
      File('${root.path}${Platform.pathSeparator}接收流程.bin')
        ..writeAsBytesSync(payload);

  Directory exportsDirectory() => Directory(
    '${root.path}${Platform.pathSeparator}client${Platform.pathSeparator}exports',
  );

  /// What the peer offers this session: planned, sealed and staged on the sending side.
  Future<OutgoingPlan> offer() => server.engine.prepareOutgoing(
    transferId: transferId,
    direction: TransferDirection.serverToClient,
    peerId: server.payload?.sessionId,
    choices: <OutgoingFileChoice>[
      OutgoingFileChoice(
        fileId: fileId,
        relativePath: '接收流程.bin',
        path: offeredFile().path,
      ),
    ],
  );

  ReceivingFlow flow({void Function()? afterPlanCreated}) => ReceivingFlow(
    engine: client.engine,
    wire: wire,
    now: () => 1000,
    outputPlans: _ObservingOutputPlans(
      client.database,
      afterCreate: afterPlanCreated,
    ),
  );

  File writtenFile(Directory exports) => exports
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => !f.path.endsWith('.nearsend-part'))
      .single;

  test('an offer becomes a verified file on this device', () async {
    final OutgoingPlan plan = await offer();
    bool observedPreAcceptancePlan = false;
    final ReceivingFlow subject = flow(
      afterPlanCreated: () {
        observedPreAcceptancePlan = true;
        expect(server.authorizations.read(transferId)?.isAccepted, isNot(true));
        expect(client.tasks.committedBytesForTask(transferId), 0);
      },
    );

    // §6: what is being offered is learned by asking, and the peer's digest is what this device
    // commits to when it answers.
    final List<OfferSummary> offers = await subject.refresh();
    expect(offers.map((OfferSummary o) => o.transferId), contains(transferId));
    expect(subject.phase, ReceivePhase.offered);
    expect(offers.single.totalBytes, payload.length);

    final Directory exports = exportsDirectory();
    final List<int> received = <int>[];
    final bool ok = await subject.accept(
      offers.single,
      saveLocationRef: exports.path,
      outputNames: const <String, String>{fileId: '本地副本.bin'},
      onFileProgress: (int count, int total) {
        received.add(count);
        expect(total, plan.manifest.files.single.chunkCount);
      },
    );

    expect(ok, isTrue, reason: 'accept failed: ${subject.failureReason}');
    expect(subject.phase, ReceivePhase.saved);
    expect(observedPreAcceptancePlan, isTrue);
    expect(
      received,
      List<int>.generate(
        plan.manifest.files.single.chunkCount,
        (int i) => i + 1,
      ),
      reason:
          'each chunk is committed before the next is asked for, in order - a receiver that '
          'reported progress ahead of its own commits would be reporting a promise',
    );
    expect(
      subject.progress!.transferredBytes,
      payload.length,
      reason: 'the short last chunk is clamped by the file frozen length',
    );
    expect(
      subject.progress!.phase.label,
      '已完成',
      reason:
          'on this side the word is earned: the file was verified against the frozen manifest and '
          'saved where the user asked',
    );
    expect(
      subject.savedPaths,
      hasLength(1),
      reason:
          'a file that verified and saved has a location, and it is reported',
    );
    expect(
      sha256.convert(writtenFile(exports).readAsBytesSync()).toString(),
      sha256.convert(payload).toString(),
      reason:
          'the flow exists so that an offer becomes a file on this device; this is the assertion '
          'that says it does',
    );
    expect(writtenFile(exports).uri.pathSegments.last, '本地副本.bin');
    final ReceiveOutputPlan output = subject.outputPlans.read(
      transferId,
      fileId,
    )!;
    expect(output.originalPath, '接收流程.bin');
    expect(output.selectedName, '本地副本.bin');
    expect(output.finalName, '本地副本.bin');
    expect(output.state, ReceiveOutputState.saved);
    expect(plan.manifest.files.single.relativePath, '接收流程.bin');

    // §10: the sender learns that this device saved the file, and that is all it can know.
    expect(server.transfers.taskState(transferId).wireName, 'COMPLETED');
    expect(
      client.tasks.committedBytesForTask(transferId),
      payload.length,
      reason:
          'the receiver rows are the authority on progress, and they hold every byte that was '
          'committed',
    );
  });

  test('an offer nobody accepted leaves nothing behind', () async {
    final OutgoingPlan plan = await offer();
    final ReceivingFlow subject = flow();
    await subject.refresh();

    // The other answer on the confirmation screen. It is taken on the wire rather than through the
    // flow, because the flow's own entry point is 接受 and a refusal must also be recordable.
    await wire.decide(
      transferId: transferId,
      manifestDigest: plan.manifestDigest,
      accept: false,
    );

    expect(server.transfers.taskState(transferId).wireName, 'CANCELLED');
    expect(
      server.authorizations.read(transferId)?.isAccepted,
      isNot(true),
      reason: 'a refused transfer must not leave an approval behind',
    );
    expect(
      client.tasks.committedBytesForTask(transferId),
      0,
      reason: 'nothing may have been written for a transfer that was never accepted',
    );
    expect(
      exportsDirectory().existsSync(),
      isFalse,
      reason:
          'no bytes means no target directory either: creating one would leave the trace of a '
          'transfer that never happened',
    );
    expect(subject.phase, ReceivePhase.offered);
    expect(subject.outputPlans.readTransfer(transferId), isEmpty);
  });
}

class _ObservingOutputPlans extends ReceiveOutputPlanRepository {
  _ObservingOutputPlans(super.database, {this.afterCreate});

  final void Function()? afterCreate;

  @override
  List<ReceiveOutputPlan> create({
    required String transferId,
    required List<ReceiveOutputChoice> choices,
    required String targetRef,
    NameConflictPolicy conflictPolicy = NameConflictPolicy.autoRename,
  }) {
    final List<ReceiveOutputPlan> plans = super.create(
      transferId: transferId,
      choices: choices,
      targetRef: targetRef,
      conflictPolicy: conflictPolicy,
    );
    afterCreate?.call();
    return plans;
  }
}
