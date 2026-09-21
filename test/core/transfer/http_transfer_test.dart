import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/network/task_authorization_endpoint.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';
import 'package:nearsend/core/protocol/transfer_resume_request.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/storage/local_file_layer.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/core/transfer/near_send_node.dart';
import 'package:nearsend/core/transfer/transfer_client.dart';
import 'package:nearsend/core/transfer/transfer_engine.dart';

/// Two nodes, one real TLS connection, one real file each way.
///
/// ## What this run is for
///
/// Every earlier test exercised one layer. This one runs the **whole stack**: a pinned HTTPS
/// connection to a real `HttpsControlServer`, §3's pairing over it, §7's routes behind the real
/// authoriser, §8's chunk transport with its framing and generation checks, §9's generation
/// allocation, and §10's completion - with the receiver's own SQLite rows and the bytes on disk
/// as the only things asserted.
///
/// It is deliberately **not** a substitute for the device run. The ledger records them as
/// different claims: this one says the protocol and the storage agree; only two real devices can
/// say whether Android's TLS stack, its file access and its durability behave the same way.
void main() {
  late Directory root;
  late NearSendNode server;
  late NearSendNode client;
  late TransferClient wire;

  /// Longer than one chunk, with a UTF-8 name, so §5.1, §5.3 and §8's tail rule all apply.
  final Uint8List payload = Uint8List.fromList(<int>[
    ...List<int>.generate(
      ProtocolLimits.chunkSizeBytes + 4096,
      (int i) => i % 251,
    ),
    ...'中文文件名.bin'.codeUnits,
  ]);

  String sha(Uint8List bytes) => sha256.convert(bytes).toString();

  Future<void> writeFile(File file, Uint8List bytes) async {
    await file.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('nearsend-http-');
    server = await NearSendNode.open(
      directory: '${root.path}${Platform.pathSeparator}server',
      candidateAddresses: const <String>['127.0.0.1'],
    );
    await server.start();

    client = await NearSendNode.open(
      directory: '${root.path}${Platform.pathSeparator}client',
      candidateAddresses: const <String>['127.0.0.1'],
    );

    // §3's payload carries candidates with the port the node was configured with, and this node
    // asked the system for a free one. The client therefore takes the *bound* port; the pin,
    // which is what trust rests on, still comes from the payload and nowhere else.
    final PairingPayload pairingPayload = server.openPairingSession();
    wire = TransferClient(
      pin: pairingPayload.serverFingerprint,
      host: '127.0.0.1',
      port: server.server.boundPort,
    );
    await wire.pairFrom(pairingPayload, clientLabel: 'test-client');
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

  test('client_to_server: a real file crosses a real TLS connection', () async {
    const String transferId = '11111111-2222-4333-8444-555555555555';
    const String fileId = '00000000-0000-4000-8000-000000000001';
    final File source = File('${root.path}${Platform.pathSeparator}中文文件名.bin');
    await writeFile(source, payload);

    // --- the client plans and proposes ---
    final OutgoingPlan plan = await client.engine.prepareOutgoing(
      transferId: transferId,
      direction: TransferDirection.clientToServer,
      choices: <OutgoingFileChoice>[
        OutgoingFileChoice(
          fileId: fileId,
          relativePath: '中文文件名.bin',
          path: source.path,
        ),
      ],
    );

    await wire.createTransfer(
      transferId: transferId,
      manifestDigest: plan.manifestDigest,
      fileCount: 1,
      totalBytes: payload.length,
    );
    await wire.uploadManifest(
      transferId: transferId,
      manifest: plan.manifest,
      pages: client.engine.pagesFor(plan.manifest, plan.files),
    );
    await wire.seal(
      transferId: transferId,
      manifestDigest: plan.manifestDigest,
    );

    expect(
      server.transfers.taskState(transferId),
      TransferState.waitingAccept,
      reason:
          'the seal froze the manifest on the server and nothing has moved yet',
    );

    // --- the server, as receiver, accepts ---
    final Directory exports = Directory(
      '${root.path}${Platform.pathSeparator}server${Platform.pathSeparator}exports',
    );
    server.engine.acceptLocally(
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

    // --- §3 delivers the resume secret, then §9 allocates a generation ---
    final grant = await wire.fetchAuthorization(transferId: transferId);
    final resumed = await wire.resume(
      transferId: transferId,
      manifestDigest: plan.manifestDigest,
      taskResumeSecret: grant.taskResumeSecret,
    );
    expect(
      resumed.leaseEpoch,
      1,
      reason: '§8 allocates the first write generation at the first resume',
    );

    // --- the client streams the file, proving backpressure by awaiting each answer ---
    final SourceFilePlan sourcePlan = client.engine.planFor(transferId, fileId);
    int sent = 0;
    for (final ChunkRecord chunk in sourcePlan.chunks) {
      final Uint8List bytes = _readChunk(sourcePlan, chunk.index);
      final result = await wire.putChunk(
        transferId: transferId,
        fileId: fileId,
        index: chunk.index,
        bytes: bytes,
        leaseEpoch: resumed.leaseEpoch,
        manifestDigest: plan.manifestDigest,
      );
      expect(result.index, chunk.index);
      sent++;
    }
    expect(sent, plan.manifest.files.single.chunkCount);

    // --- the server verifies from its own rows and exports ---
    final ReceivedFileOutcome outcome = await server.engine.finishFile(
      fileId: fileId,
      targetRef: exports.path,
    );
    expect(outcome.verification.wholeFileDigestMatches, isTrue);
    expect(outcome.verification.verifiedBytes, payload.length);

    final List<File> written = exports
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => !f.path.endsWith('.nearsend-part'))
        .toList();
    expect(written, hasLength(1));
    expect(
      sha(Uint8List.fromList(written.single.readAsBytesSync())),
      sha(payload),
      reason:
          'the file that reached the disk must hash to the file that left the sender - this '
          'is the assertion that makes the transfer real rather than plausible',
    );
    expect(
      server.tasks.isFullyCommitted(fileId),
      isTrue,
      reason: 'and the receiver own rows must agree',
    );
  });

  test('server_to_client: the client pulls a real file over TLS', () async {
    const String transferId = '22222222-3333-4444-8555-666666666666';
    const String fileId = '00000000-0000-4000-8000-000000000002';
    final File source = File(
      '${root.path}${Platform.pathSeparator}server${Platform.pathSeparator}中文文件名.bin',
    );
    await writeFile(source, payload);

    // --- the server plans, seals and binds the transfer to the paired session ---
    final OutgoingPlan plan = await server.engine.prepareOutgoing(
      transferId: transferId,
      direction: TransferDirection.serverToClient,
      peerId: wire.sessionToken == null ? null : _sessionIdOf(server),
      choices: <OutgoingFileChoice>[
        OutgoingFileChoice(
          fileId: fileId,
          relativePath: '中文文件名.bin',
          path: source.path,
        ),
      ],
    );

    // --- the client learns about it, decides, and gets its credentials ---
    final offers = await wire.offers();
    expect(
      offers.map((o) => o.transferId),
      contains(transferId),
      reason: '§6 lists offers to the session the transfer is bound to',
    );
    expect(offers.first.manifestDigest, plan.manifestDigest);
    expect(offers.first.totalBytes, payload.length);

    await wire.decide(
      transferId: transferId,
      manifestDigest: plan.manifestDigest,
      accept: true,
    );
    expect(
      server.authorizations.read(transferId)!.isAccepted,
      isTrue,
      reason: '§6 persists the approval, the digest and the location together',
    );

    final grant = await wire.fetchAuthorization(transferId: transferId);
    final resumed = await wire.resume(
      transferId: transferId,
      manifestDigest: plan.manifestDigest,
      taskResumeSecret: grant.taskResumeSecret,
      receiverState: const ReceiverState(
        leaseEpoch: 0,
        checkpointSeq: 0,
        committedBytes: 0,
      ),
    );

    // --- the client reads the frozen manifest the server sealed ---
    final FrozenManifest manifest = await wire.readManifest(transferId);
    expect(manifest.manifestDigest, plan.manifestDigest);
    final ManifestFile file = manifest.files.single;
    final List<ChunkRecord> records = await wire.readChunkRecords(
      transferId: transferId,
      file: file,
    );
    expect(records.length, file.chunkCount);

    client.engine.registerRemoteManifest(transferId, manifest);
    client.engine.registerRemoteFile(
      transferId: transferId,
      file: file,
      chunks: records,
    );

    // --- §9: the client is the receiver, so it persists the granted generation locally before it
    // can commit anything against it. This happens after the task row exists, because the
    // generation is written onto that row. ---
    client.tasks.adoptLeaseEpoch(transferId, epoch: resumed.leaseEpoch);
    expect(
      client.tasks.leaseEpoch(transferId),
      resumed.leaseEpoch,
      reason:
          'without this the receiver would present generation 0 and every commit would be '
          'refused as stale',
    );

    // --- the client pulls exactly what its own rows say is missing ---
    final List<int> missing = client.engine.missingChunks(fileId);
    expect(missing, hasLength(file.chunkCount));
    for (final int index in missing) {
      final Uint8List bytes = await wire.getChunk(
        transferId: transferId,
        fileId: fileId,
        index: index,
        leaseEpoch: resumed.leaseEpoch,
        manifestDigest: plan.manifestDigest,
      );
      await client.engine.acceptChunk(
        transferId: transferId,
        fileId: fileId,
        index: index,
        bytes: bytes,
        leaseEpoch: resumed.leaseEpoch,
      );
    }
    expect(
      client.engine.missingChunks(fileId),
      isEmpty,
      reason: 'nothing is left to ask for',
    );

    final Directory exports = Directory(
      '${root.path}${Platform.pathSeparator}client${Platform.pathSeparator}exports',
    );
    final ReceivedFileOutcome outcome = await client.engine.finishFile(
      fileId: fileId,
      targetRef: exports.path,
    );
    expect(outcome.verification.wholeFileDigestMatches, isTrue);

    final List<File> written = exports
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => !f.path.endsWith('.nearsend-part'))
        .toList();
    expect(written, hasLength(1));
    expect(
      sha(Uint8List.fromList(written.single.readAsBytesSync())),
      sha(payload),
      reason: 'the pulled file is byte-identical to what the server held',
    );

    // --- §9's mirror: the client reports, the sender only records ---
    await wire.reportCheckpoint(
      transferId: transferId,
      manifestDigest: plan.manifestDigest,
      leaseEpoch: resumed.leaseEpoch,
      checkpointSeq: client.tasks.checkpointSeq(transferId),
      committedBytes: client.tasks.committedBytesForTask(transferId),
    );
    expect(
      server.mirror.read(transferId)?.committedBytes,
      payload.length,
      reason: 'the sender keeps the reported figure for display',
    );
    expect(
      server.tasks.committedBytesForTask(transferId),
      0,
      reason:
          'and it must not appear in the sender own rows: §9 makes the receiver the only '
          'authority on progress and the sender record a mirror',
    );

    // --- §10: the client reports it saved the file, which is all the sender can know ---
    await wire.complete(
      transferId: transferId,
      fileId: fileId,
      leaseEpoch: resumed.leaseEpoch,
      saved: true,
      fileSha256: file.fileSha256,
    );
    expect(
      server.transfers.taskState(transferId),
      TransferState.completed,
      reason: 'the sender records the peer report of completion',
    );
  });
}

/// The session id the server issued, which is what a transfer is bound to.
String _sessionIdOf(NearSendNode node) => node.payload!.sessionId;

/// Reads one chunk of a planned source with a single bounded buffer.
Uint8List _readChunk(SourceFilePlan plan, int index) {
  final RandomAccessFile handle = plan.file!.openSync();
  try {
    final ChunkRecord record = plan.chunks[index];
    handle.setPositionSync(index * ProtocolLimits.chunkSizeBytes);
    final Uint8List bytes = Uint8List(record.length);
    int filled = 0;
    while (filled < record.length) {
      final int read = handle.readIntoSync(
        bytes,
        filled,
        record.length - filled,
      );
      if (read <= 0) {
        break;
      }
      filled += read;
    }
    return bytes;
  } finally {
    handle.closeSync();
  }
}
