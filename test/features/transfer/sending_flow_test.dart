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
import 'package:nearsend/core/transfer/transfer_engine.dart';
import 'package:nearsend/features/transfer/application/file_selection_controller.dart';
import 'package:nearsend/features/transfer/application/sending_flow.dart';
import 'package:nearsend/features/transfer/application/sending_session.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';
import 'package:nearsend/platform/android_file_gateway.dart';

/// The send flow, from a selection to bytes on the receiving disk.
///
/// The cases below are the two things the screens around this class cannot show on their own: that
/// the sender **waits** for the peer's decision instead of pushing bytes into a refusal, and that a
/// selection made of either kind of reference - a document or a path - ends as the same bytes at the
/// receiver.
void main() {
  late Directory root;
  late NearSendNode server;
  late NearSendNode client;
  late TransferClient wire;
  late InMemoryFileGateway documents;
  late FileSelectionController controller;
  late Directory exports;

  const String transferId = '11111111-2222-4333-8444-555555555555';
  const String fileId = '00000000-0000-4000-8000-000000000001';

  final Uint8List payload = Uint8List.fromList(<int>[
    ...List<int>.generate(
      ProtocolLimits.chunkSizeBytes + 777,
      (int i) => i % 199,
    ),
    ...'流程编排.bin'.codeUnits,
  ]);

  String safUri(String id) => 'content://nearsend.test/$id';

  setUp(() async {
    root = Directory.systemTemp.createTempSync('nearsend-flow-');
    exports = Directory('${root.path}${Platform.pathSeparator}exports');
    documents = InMemoryFileGateway(
      documents: <String, Uint8List>{safUri(fileId): payload},
    );
    documents.nextPick = <PickedDocument>[
      PickedDocument(
        uri: safUri(fileId),
        displayName: '流程编排.bin',
        sizeBytes: payload.length,
      ),
    ];

    SourceBytes resolve(String ref, int size) => ref.startsWith('content://')
        ? SafSourceBytes(
            gateway: documents,
            uri: ref,
            providerReportedSize: size,
          )
        : FileSourceBytes(File(ref));

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
    await wire.pairFrom(pairingPayload, clientLabel: 'flow-test');

    controller = FileSelectionController(
      gateway: documents,
      idFactory: () => fileId,
    );
  });

  tearDown(() async {
    wire.close();
    await server.stop();
    server.close();
    client.close();
    if (root.existsSync()) {
      // A failing case can leave a poll or a write in flight for a moment; the directory is a
      // scratch one either way, and a cleanup error here would mask the assertion that failed.
      try {
        root.deleteSync(recursive: true);
      } on Object {
        // ignored on purpose
      }
    }
  });

  SendingFlow flow({
    Duration authorizationTimeout = const Duration(seconds: 20),
  }) => SendingFlow(
    session: SendingSession(engine: client.engine, wire: wire),
    selection: controller,
    now: () => 1000,
    transferIdFactory: () => transferId,
    authorizationPollInterval: const Duration(milliseconds: 20),
    authorizationTimeout: authorizationTimeout,
  );

  /// Accepts the offer on the receiving side, which on a server that is not the addressee is a local
  /// decision.
  void accept() => server.engine.acceptLocally(
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

  /// Waits for [condition] while real I/O runs.
  Future<void> waitFor(bool Function() condition) async {
    final Stopwatch waited = Stopwatch()..start();
    while (!condition() && waited.elapsed < const Duration(seconds: 20)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Whether the receiver has a row for the offer yet.
  ///
  /// The row does not exist until the proposal arrives, so the poll has to treat "not yet" as an
  /// answer rather than as an error.
  bool offerSealed() {
    try {
      return server.transfers.taskState(transferId).wireName ==
          'WAITING_ACCEPT';
    } on Object {
      return false;
    }
  }

  /// The file the receiver wrote, excluding its own staging parts.
  File writtenFile() => exports
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => !f.path.endsWith('.nearsend-part'))
      .single;

  test('a selected document becomes a verified file on the receiver', () async {
    final SendingFlow subject = flow();
    await subject.pick();

    expect(subject.phase, SendPhase.ready);
    expect(subject.report.canSend, isTrue);
    expect(subject.files.single.displayName, '流程编排.bin');

    final List<SendPhase> phases = <SendPhase>[];
    subject.addListener(() => phases.add(subject.phase));

    final Future<bool> sending = subject.send();
    // The peer has not decided yet, and nothing may move before it does.
    await waitFor(offerSealed);
    expect(
      server.tasks.committedBytesForTask(transferId),
      0,
      reason:
          '§6 forbids touching file bytes before acceptance, so an offer that is sealed and not '
          'yet accepted must have committed nothing',
    );
    accept();

    expect(await sending, isTrue);
    expect(
      subject.phase,
      SendPhase.awaitingVerification,
      reason:
          'the sender knows the bytes arrived and knows nothing about verification or saving; '
          'claiming completion here is the false completion §7 warns about',
    );
    expect(phases, contains(SendPhase.waitingForPeer));
    expect(phases, contains(SendPhase.sending));

    // Progress is per acknowledged chunk, from the protocol's chunk length, and clamped to the
    // file's frozen size - so the short last chunk cannot push it past the total. The figure says
    // the bytes of this file are all sent, and the phase stays 传输中: the sender has no basis for
    // 已完成, because the peer has not verified or saved anything yet.
    final progress = subject.progress!;
    expect(progress.transferredBytes, payload.length);
    expect(progress.fraction, 1.0);
    expect(progress.remainingLabel, '本文件已传完');
    expect(progress.phase, isNot(TransferPhase.completed));

    final ReceivedFileOutcome outcome = await server.engine.finishFile(
      fileId: fileId,
      targetRef: exports.path,
    );
    expect(outcome.verification.wholeFileDigestMatches, isTrue);
    expect(
      sha256.convert(writtenFile().readAsBytesSync()).toString(),
      sha256.convert(payload).toString(),
      reason:
          'the flow exists so that a selection becomes a file at the receiver; this is the '
          'assertion that says it does',
    );
  });

  test('the sender waits for the decision instead of pushing bytes', () async {
    // A short bound so the case is not a twenty-second wait: the property under test is that the
    // wait exists and ends in a stated reason, not how long the default bound is.
    final SendingFlow subject = flow(
      authorizationTimeout: const Duration(milliseconds: 600),
    );
    await subject.pick();

    final Future<bool> sending = subject.send();
    await waitFor(() => subject.phase == SendPhase.waitingForPeer);

    expect(subject.phase, SendPhase.waitingForPeer);
    expect(
      server.tasks.committedBytesForTask(transferId),
      0,
      reason:
          'a sender that moved bytes before the receiver accepted would be sending into a '
          'refusal, and §7 answers that refusal with 404 rather than with progress',
    );

    // Nobody accepts: the wait is bounded, and the bound is a state the screen can show rather
    // than an unbounded spinner.
    expect(await sending, isFalse);
    expect(subject.phase, SendPhase.failed);
    expect(subject.failureReason, contains('超时'));
    expect(
      server.tasks.committedBytesForTask(transferId),
      0,
      reason: 'giving up must not have pushed anything either',
    );
  });

  test('a path platform selects by path and sends the same bytes', () async {
    final Directory source = Directory(
      '${root.path}${Platform.pathSeparator}source',
    )..createSync();
    final File file = File('${source.path}${Platform.pathSeparator}路径来源.bin')
      ..writeAsBytesSync(payload);

    final SendingFlow subject = flow();
    await subject.addPaths(<String>[file.path]);

    expect(subject.phase, SendPhase.ready);
    expect(subject.report.totalBytes, payload.length);
    expect(
      controller.choicesFor(subject.report).single.path,
      file.path,
      reason:
          'a path reference must stay a path: routing it through the SAF channel would ask a '
          'platform that has no such channel to open it',
    );

    final Future<bool> sending = subject.send();
    await waitFor(offerSealed);
    accept();

    expect(await sending, isTrue);
    final ReceivedFileOutcome outcome = await server.engine.finishFile(
      fileId: fileId,
      targetRef: exports.path,
    );
    expect(outcome.verification.wholeFileDigestMatches, isTrue);
    expect(
      sha256.convert(writtenFile().readAsBytesSync()).toString(),
      sha256.convert(payload).toString(),
    );
  });

  test('a path that cannot be read is a reason, not a late failure', () async {
    final SendingFlow subject = flow();
    await subject.addPaths(<String>[
      '${root.path}${Platform.pathSeparator}missing.bin',
    ]);

    expect(subject.phase, SendPhase.empty);
    expect(subject.report.canSend, isFalse);
    expect(
      subject.report.problems.join('|'),
      contains('无法读取文件'),
      reason:
          'a file that cannot be read must be refused where the user can fix it, rather than '
          'inside planning where the message would be about hashing',
    );
    expect(await subject.send(), isFalse);
  });
}
