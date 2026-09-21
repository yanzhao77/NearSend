import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/network/task_authorization_endpoint.dart';
import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';
import 'package:nearsend/core/protocol/transfer_resume_request.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/storage/local_file_layer.dart';
import 'package:nearsend/core/storage/source_bytes.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/core/transfer/near_send_node.dart';
import 'package:nearsend/core/transfer/transfer_client.dart';
import 'package:nearsend/core/transfer/transfer_engine.dart';
import 'package:nearsend/platform/android_file_gateway.dart';

/// Two nodes, one real TLS connection, one document each way.
///
/// ## What this run is for
///
/// Every earlier test exercised one layer. This one runs the **whole stack**: a pinned HTTPS
/// connection to a real `HttpsControlServer`, §3's pairing over it, §7's routes behind the real
/// authoriser, §8's chunk transport with its framing and generation checks, §9's generation
/// allocation, and §10's completion - with the receiver's own SQLite rows and the bytes on disk as
/// the only things asserted.
///
/// ## The sending side reads from a document, not a path
///
/// Both cases point their sender at a **`content://` document** backed by an in-memory gateway and
/// resolved by the same `sourceResolver` an Android node installs. That is the difference between
/// "the SAF adapter compiles" and "a device can send": the bytes travel from a document, through
/// planning and §8's chunk transport, into a file on the receiver, and the digests are compared.
///
/// It is deliberately **not** a substitute for the device run. The ledger records them as different
/// claims: this one says the protocol and the storage agree; only two real devices can say whether
/// Android's TLS stack, its document provider and its durability behave the same way.
void main() {
  late Directory root;
  late NearSendNode server;
  late NearSendNode client;
  late TransferClient wire;
  late InMemoryFileGateway senderDocuments;

  /// The document URI a sending side reads from, keyed by the file id the manifest carries so each
  /// case is pointed at its own document.
  String safUri(String fileId) => 'content://nearsend.test/$fileId';

  /// Resolves a recorded reference the way an Android node does: a document for `content://`, a
  /// path otherwise. Passing this to both nodes is what makes the SAF path reachable at all.
  SourceBytes resolveSource(
    InMemoryFileGateway gateway,
    String ref,
    int size,
  ) => ref.startsWith('content://')
      ? SafSourceBytes(gateway: gateway, uri: ref, providerReportedSize: size)
      : FileSourceBytes(File(ref));

  /// Longer than one chunk, with a UTF-8 name, so §5.1, §5.3 and §8's tail rule all apply.
  final Uint8List payload = Uint8List.fromList(<int>[
    ...List<int>.generate(
      ProtocolLimits.chunkSizeBytes + 4096,
      (int i) => i % 251,
    ),
    ...'中文文件名.bin'.codeUnits,
  ]);

  String sha(Uint8List bytes) => sha256.convert(bytes).toString();

  /// A sending choice whose bytes come from a document rather than a path.
  OutgoingFileChoice documentChoice({
    required String fileId,
    required String relativePath,
  }) => OutgoingFileChoice(
    fileId: fileId,
    relativePath: relativePath,
    source: SafSourceBytes(
      gateway: senderDocuments,
      uri: safUri(fileId),
      providerReportedSize: payload.length,
    ),
  );

  setUp(() async {
    root = Directory.systemTemp.createTempSync('nearsend-http-');

    senderDocuments = InMemoryFileGateway(
      documents: <String, Uint8List>{
        safUri('00000000-0000-4000-8000-000000000001'): payload,
        safUri('00000000-0000-4000-8000-000000000002'): payload,
      },
    );
    SourceBytes resolve(String ref, int size) =>
        resolveSource(senderDocuments, ref, size);

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

    // §3's payload carries candidates with the port the node was configured with, and this node
    // asked the system for a free one. The client therefore takes the *bound* port; the pin, which
    // is what trust rests on, still comes from the payload and nowhere else.
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

  test('client_to_server: a document crosses a real TLS connection', () async {
    const String transferId = '11111111-2222-4333-8444-555555555555';
    const String fileId = '00000000-0000-4000-8000-000000000001';

    // --- the client plans from a document and proposes ---
    final OutgoingPlan plan = await client.engine.prepareOutgoing(
      transferId: transferId,
      direction: TransferDirection.clientToServer,
      choices: <OutgoingFileChoice>[
        documentChoice(fileId: fileId, relativePath: '中文文件名.bin'),
      ],
    );

    expect(
      plan.files.single.manifest.fileSha256,
      sha(payload),
      reason:
          '§5.2 hashes the raw bytes, so a manifest built from a document must describe the '
          'same content a file would have',
    );
    expect(
      plan.files.single.file,
      isNull,
      reason: 'a SAF source has no path, and pretending it has one is what §9 forbids',
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
    final AuthorizationGrant grant = await wire.fetchAuthorization(
      transferId: transferId,
    );
    final ResumeGranted resumed = await wire.resume(
      transferId: transferId,
      manifestDigest: plan.manifestDigest,
      taskResumeSecret: grant.taskResumeSecret,
    );
    expect(
      resumed.leaseEpoch,
      1,
      reason: '§8 allocates the first write generation at the first resume',
    );

    // --- the client streams the document, proving backpressure by awaiting each answer ---
    final SourceFilePlan sourcePlan = client.engine.planFor(transferId, fileId);
    for (final ChunkRecord chunk in sourcePlan.chunks) {
      final Uint8List bytes = await sourcePlan.source.readAt(
        offset: chunk.index * ProtocolLimits.chunkSizeBytes,
        length: chunk.length,
      );
      final ChunkWriteResult result = await wire.putChunk(
        transferId: transferId,
        fileId: fileId,
        index: chunk.index,
        bytes: bytes,
        leaseEpoch: resumed.leaseEpoch,
        manifestDigest: plan.manifestDigest,
      );
      expect(result.index, chunk.index);
    }
    expect(sourcePlan.chunks, hasLength(plan.manifest.files.single.chunkCount));

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
          'the bytes that reached the disk came out of a document on the other node and must '
          'hash to what the document held - the assertion that makes a device able to send '
          'rather than merely compile',
    );
    expect(server.tasks.isFullyCommitted(fileId), isTrue);
  });

  test('server_to_client: the client pulls a document-backed file', () async {
    const String transferId = '22222222-3333-4444-8555-666666666666';
    const String fileId = '00000000-0000-4000-8000-000000000002';

    // --- the server plans from a document, seals, and binds to the session ---
    final OutgoingPlan plan = await server.engine.prepareOutgoing(
      transferId: transferId,
      direction: TransferDirection.serverToClient,
      peerId: server.payload?.sessionId,
      choices: <OutgoingFileChoice>[
        documentChoice(fileId: fileId, relativePath: '中文文件名.bin'),
      ],
    );

    // --- the client learns about it, decides, and gets its credentials ---
    final List<OfferSummary> offers = await wire.offers();
    final OfferSummary offer = offers.firstWhere(
      (OfferSummary o) => o.transferId == transferId,
    );
    expect(
      offer.manifestDigest,
      plan.manifestDigest,
      reason: '§6 lists offers to the session the transfer is bound to',
    );
    expect(offer.totalBytes, payload.length);

    await wire.decide(
      transferId: transferId,
      manifestDigest: offer.manifestDigest,
      accept: true,
    );
    expect(
      server.authorizations.read(transferId)!.isAccepted,
      isTrue,
      reason: '§6 persists the approval, the digest and the location together',
    );

    final AuthorizationGrant grant = await wire.fetchAuthorization(
      transferId: transferId,
    );
    final ResumeGranted resumed = await wire.resume(
      transferId: transferId,
      manifestDigest: offer.manifestDigest,
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
    expect(records, hasLength(file.chunkCount));

    client.engine.registerRemoteManifest(transferId, manifest);
    client.engine.registerRemoteFile(
      transferId: transferId,
      file: file,
      chunks: records,
    );
    // §9: the client is the receiver but the server allocated the generation, so the client
    // persists it locally before it can commit anything against it.
    client.tasks.adoptLeaseEpoch(transferId, epoch: resumed.leaseEpoch);

    // --- the client pulls exactly what its own rows say is missing ---
    final List<int> missing = client.engine.missingChunks(fileId);
    expect(missing, hasLength(file.chunkCount));
    for (final int index in missing) {
      final Uint8List bytes = await wire.getChunk(
        transferId: transferId,
        fileId: fileId,
        index: index,
        leaseEpoch: resumed.leaseEpoch,
        manifestDigest: offer.manifestDigest,
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
      reason:
          'the pulled file is byte-identical to the document the server read',
    );

    // --- §9's mirror: the client reports, the sender only records ---
    await wire.reportCheckpoint(
      transferId: transferId,
      manifestDigest: offer.manifestDigest,
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
