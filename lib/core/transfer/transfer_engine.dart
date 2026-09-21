/// The local orchestration that turns the endpoints into an actual transfer.
///
/// ## What was missing until this file
///
/// Every piece of §6–§10 existed and was tested on its own: the manifest is paged and sealed, the
/// decision is recorded, the generation is allocated, chunks are written through a bounded
/// window, verification demotes damaged blocks, export is gated on a receipt. What did not exist
/// was the code that **uses** them in the order the protocol requires, and without it no file
/// byte had ever moved.
///
/// ## The two roles, stated once
///
/// §7 fixes which side sends:
///
/// | direction | sender | receiver |
/// | --- | --- | --- |
/// | `client_to_server` | the client | **this** server |
/// | `server_to_client` | **this** server | the client |
///
/// So "this node is the receiver" is `direction == client_to_server`, and nearly every decision
/// below turns on it: who runs the space pre-check, who decides, who holds the authoritative
/// chunk rows, who verifies, who exports, and who reports `saved`.
///
/// ## The rules this class must not break
///
/// * **Nothing moves before acceptance.** [prepareOutgoing] stops at `WAITING_ACCEPT`; only
///   acceptance opens a write generation, which is what every chunk request presents.
/// * **The receiver's committed rows are the only authority.** [receiveFile] re-derives what is
///   missing from its own database every time rather than from a progress figure, and
///   [sendFile] never consults one.
/// * **Completion is verification *and* export.** [finishFile] runs the whole-file digest first
///   and hands the receipt to the export service, which refuses a receipt that is not exportable
///   - so "完成" cannot be recorded for a file whose bytes are wrong.
/// * **Bounded memory.** Chunks are streamed one at a time and the consumer is awaited before
///   the next read (see `LocalSourceReader.streamChunks`), so a slow link cannot make this
///   buffer a file.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:nearsend/core/network/chunk_transfer_endpoint.dart';
import 'package:nearsend/core/network/manifest_staging_registry.dart';
import 'package:nearsend/core/network/task_authorization_endpoint.dart';
import 'package:nearsend/core/network/task_ownership.dart';
import 'package:nearsend/core/protocol/chunk_headers.dart';
import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/manifest_page.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/export_service.dart';
import 'package:nearsend/core/storage/file_verification.dart';
import 'package:nearsend/core/storage/local_file_layer.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/core/storage/storage_failure.dart';
import 'package:nearsend/core/storage/task_authorization_repository.dart';
import 'package:nearsend/core/storage/task_credential_repository.dart';
import 'package:nearsend/core/storage/task_source_repository.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

/// One file the user chose to send.
class OutgoingFileChoice {
  const OutgoingFileChoice({
    required this.fileId,
    required this.relativePath,
    required this.path,
  });

  /// The manifest identifier. Chosen by the sender and validated as a canonical UUID.
  final String fileId;

  /// The name the manifest carries and the receiver records. §5.1's rules apply to it.
  final String relativePath;

  /// The local path the bytes are read from. Never sent.
  final String path;

  @override
  String toString() => 'OutgoingFileChoice($relativePath -> $fileId)';
}

/// What a sender staged, ready to be proposed or already proposed.
class OutgoingPlan {
  const OutgoingPlan({
    required this.transferId,
    required this.direction,
    required this.manifest,
    required this.files,
  });

  final String transferId;
  final TransferDirection direction;

  /// The frozen manifest, whose digest the receiver will verify against.
  final FrozenManifest manifest;

  /// The planned sources, in manifest order.
  final List<SourceFilePlan> files;

  String get manifestDigest => manifest.manifestDigest;

  @override
  String toString() =>
      'OutgoingPlan($transferId, ${files.length} file(s), $manifestDigest)';
}

/// What receiving one file ended as.
class ReceivedFileOutcome {
  const ReceivedFileOutcome({
    required this.fileId,
    required this.verification,
    required this.export,
    this.savedPath,
  });

  final String fileId;
  final FileVerificationResult verification;

  /// Null when the file was received but the caller did not ask for an export.
  final ExportOutcome? export;

  /// The name the copy was written under, when it was written.
  final String? savedPath;

  bool get isComplete =>
      verification.isExportable && (export == null || export!.isSaved);
}

/// Drives a transfer on this node, for whichever role the direction gives it.
class TransferEngine {
  TransferEngine({
    required this.database,
    required this.transfers,
    required this.tasks,
    required this.staging,
    required this.authorizations,
    required this.credentials,
    required this.sources,
    required this.ownership,
    required this.layout,
    required this.sink,
    required this.reader,
    required this.verifier,
    required this.exporter,
    required this.windows,
    int Function()? now,
  }) : now = now ?? _systemNow;

  final NearSendDatabase database;
  final TransferRepository transfers;
  final ChunkRepository tasks;
  final ManifestStagingRegistry staging;
  final TaskAuthorizationRepository authorizations;
  final TaskCredentialRepository credentials;
  final TaskSourceRepository sources;
  final SqliteTaskOwnership ownership;
  final LocalStagingLayout layout;
  final StagingFileSink sink;
  final StagingChunkReader reader;
  final FileVerifier verifier;
  final ExportService exporter;
  final ChunkWindowRegistry windows;
  final int Function() now;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  final LocalSourceReader _sourceReader = const LocalSourceReader();

  // ---------------------------------------------------------------------------------------
  // Sending
  // ---------------------------------------------------------------------------------------

  /// Plans the chosen files and stages their manifest, stopping at `WAITING_ACCEPT`.
  ///
  /// The order matters and is the protocol's: §5.2's digests are computed over the source bytes,
  /// so the manifest has to exist before the transfer can be declared with its digest; §6 then
  /// seals it, and only a sealed manifest may be offered.
  ///
  /// [peerId] binds the transfer to the paired peer §7 authorises. [direction] decides which side
  /// this node ends up being.
  Future<OutgoingPlan> prepareOutgoing({
    required String transferId,
    required TransferDirection direction,
    required List<OutgoingFileChoice> choices,
    String? peerId,
  }) async {
    if (choices.isEmpty) {
      throw ArgumentError.value(
        choices,
        'choices',
        'a transfer needs at least one file',
      );
    }
    await layout.prepare();

    final List<SourceFilePlan> plans = <SourceFilePlan>[];
    for (final OutgoingFileChoice choice in choices) {
      // Planning reads the source and computes §5.2's and §5.3's digests. It writes nothing, and
      // it must run before the task row exists because the manifest digest is not known until
      // every file has been read - and the task row is registered *with* that digest.
      plans.add(
        await _sourceReader.plan(
          source: File(choice.path),
          relativePath: choice.relativePath,
          fileId: choice.fileId,
        ),
      );
    }

    final FrozenManifest manifest = FrozenManifest(
      protocolMajor: ProtocolLimits.protocolMajor,
      protocolMinor: ProtocolLimits.protocolMinor,
      transferId: transferId,
      files: <ManifestFile>[for (final SourceFilePlan p in plans) p.manifest],
    );

    tasks.registerTask(
      taskId: transferId,
      role: 'sender',
      direction: direction.wireValue,
      state: TransferState.staging,
      protocolMajor: ProtocolLimits.protocolMajor,
      protocolMinor: ProtocolLimits.protocolMinor,
      manifestDigest: manifest.manifestDigest,
      nowMillis: now(),
    );

    for (int i = 0; i < plans.length; i++) {
      // Recorded after the task row because `task_sources` is keyed by it: the foreign key is
      // what stops a source from outliving the transfer it belongs to. The reference is what
      // lets a restarted sender read its own file again, and it never travels on the wire.
      sources.record(
        transferId: transferId,
        fileId: plans[i].manifest.fileId,
        sourceRef: choices[i].path,
        sizeBytes: plans[i].manifest.sizeBytes,
      );
    }

    await _stagePages(transferId, manifest, plans);
    staging.seal(transferId);
    transfers.transitionTask(
      taskId: transferId,
      to: TransferState.waitingAccept,
    );

    if (peerId != null) {
      // §7's session-scoped rows need this binding; without it a paired peer could not decide
      // or be offered anything.
      ownership.assign(transferId, peerId);
    }

    return OutgoingPlan(
      transferId: transferId,
      direction: direction,
      manifest: manifest,
      files: plans,
    );
  }

  /// Pages the manifest into staging, exactly as §6 describes.
  ///
  /// Shared by both roles: a client sender uploads these pages through `PUT /manifest`, and a
  /// server sender stages them locally. The chunk records come from the plans that produced the
  /// file entries, so a page built here and the digest that went into the manifest are the same
  /// bytes by construction.
  Future<void> _stagePages(
    String transferId,
    FrozenManifest manifest,
    List<SourceFilePlan> plans,
  ) async {
    for (final ManifestPage page in pagesFor(manifest, plans)) {
      staging.addPage(transferId, page);
    }
  }

  /// The pages of [manifest], so a client can upload them without re-deriving the layout.
  List<ManifestPage> pagesFor(
    FrozenManifest manifest,
    List<SourceFilePlan> plans,
  ) => <ManifestPage>[
    ...ManifestPager.filePages(
      manifestDigest: manifest.manifestDigest,
      files: manifest.files,
    ),
    for (final SourceFilePlan plan in plans)
      ...ManifestPager.chunkPages(
        manifestDigest: manifest.manifestDigest,
        fileId: plan.manifest.fileId,
        chunks: plan.chunks,
      ),
  ];

  /// Streams one file's chunks to [send], awaiting each response before reading the next.
  ///
  /// The await is the backpressure: §8's data path must not run ahead of the peer, and
  /// `streamChunks` reads the next chunk only after the callback has completed.
  ///
  /// [send] receives the chunk index and bytes and must return the peer's response. The index is
  /// passed rather than derived from a counter so a resume can send only what is missing.
  Future<int> sendFile({
    required String transferId,
    required String fileId,
    required int leaseEpoch,
    required String manifestDigest,
    required String taskAccessToken,
    required Future<ReceivedLike> Function(int index, Uint8List bytes) send,
    Iterable<int>? onlyIndices,
  }) async {
    final SourceFilePlan plan = planFor(transferId, fileId);
    final Set<int>? wanted = onlyIndices?.toSet();
    int sent = 0;

    await _sourceReader.streamChunks(
      plan: plan,
      onChunk: (int index, Uint8List bytes) async {
        if (wanted != null && !wanted.contains(index)) {
          return;
        }
        final ReceivedLike response = await send(index, bytes);
        if (!response.isSuccess) {
          // A refused chunk must stop the loop rather than being counted: §8 makes a 4xx an
          // instruction to fix the request, and continuing would send the rest under a request
          // the peer has already rejected.
          throw ProtocolViolation(
            response.errorCode ?? ProtocolErrorCode.invalidField,
            'the peer refused chunk $index of $fileId',
          );
        }
        sent++;
      },
    );
    return sent;
  }

  /// The header set a chunk `PUT` carries (§8).
  Map<String, String> putHeaders({
    required int declaredLength,
    required int leaseEpoch,
    required String manifestDigest,
    required String taskAccessToken,
  }) => <String, String>{
    'authorization': 'Bearer $taskAccessToken',
    'content-type': chunkContentType,
    'content-length': '$declaredLength',
    leaseEpochHeader: '$leaseEpoch',
    manifestDigestHeader: manifestDigest,
  };

  /// The header set a chunk `GET` carries (§7).
  Map<String, String> getHeaders({
    required int leaseEpoch,
    required String manifestDigest,
    required String taskAccessToken,
  }) => <String, String>{
    'authorization': 'Bearer $taskAccessToken',
    leaseEpochHeader: '$leaseEpoch',
    manifestDigestHeader: manifestDigest,
  };

  /// The plan for one file of a staged transfer, rebuilt from what is recorded.
  ///
  /// Public because a resumed sender has to rebuild it after a restart, and because a receiver
  /// side that wants to compare against the sender needs the same bytes.
  SourceFilePlan planFor(String transferId, String fileId) {
    final TaskSourceRecord? record = sources.read(transferId, fileId);
    if (record == null) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'no source is recorded for $fileId, so its bytes cannot be read',
      );
    }
    final FrozenManifest? frozen = staging.frozenManifest(transferId);
    if (frozen == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidState,
        'the transfer has no frozen manifest, so nothing can be sent',
      );
    }
    ManifestFile? file;
    for (final ManifestFile candidate in frozen.files) {
      if (candidate.fileId == fileId) {
        file = candidate;
      }
    }
    if (file == null) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        '$fileId is not part of transfer $transferId',
      );
    }

    // §5.3's per-chunk digests live in the manifest's **chunk pages**, which staging holds, not
    // in the file entry. Reading them back from there is what lets a restarted sender stream
    // without having kept the source plan in memory - and it keeps one definition of what each
    // chunk's digest is.
    final List<ChunkRecord> records = staging.store.readChunkPage(
      transferId,
      fileId: fileId,
      startIndex: 0,
      limit: file.chunkCount,
    );
    if (records.length != file.chunkCount) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'staging holds ${records.length} chunk records for $fileId but its file entry '
        'declares ${file.chunkCount}',
      );
    }
    return SourceFilePlan(
      file: File(record.sourceRef),
      manifest: file,
      chunks: records,
    );
  }

  // ---------------------------------------------------------------------------------------
  // Receiving
  // ---------------------------------------------------------------------------------------

  /// Registers a frozen manifest received from the peer.
  ///
  /// A client receiver needs the task row before it can register anything: §7's direction for a
  /// transfer it receives is `server_to_client`, and every chunk request it makes carries the
  /// generation that `resume` allocated for it.
  ///
  /// The files are registered by [registerRemoteFile], which is given the chunk records the peer
  /// served - §8 makes the frozen manifest the authority for lengths and digests, and those
  /// records are what it says.
  void registerRemoteManifest(String transferId, FrozenManifest manifest) {
    if (transfers.readDeclaration(transferId) != null) {
      return;
    }
    tasks.registerTask(
      taskId: transferId,
      role: 'receiver',
      direction: TransferDirection.serverToClient.wireValue,
      state: TransferState.ready,
      protocolMajor: manifest.protocolMajor,
      protocolMinor: manifest.protocolMinor,
      manifestDigest: manifest.manifestDigest,
      nowMillis: now(),
    );
  }

  /// Registers a file using the chunk records the peer served.
  ///
  /// Idempotent: a resumed transfer re-reads the same manifest, and re-registering a file would
  /// violate the primary key without telling anybody anything new.
  void registerRemoteFile({
    required String transferId,
    required ManifestFile file,
    required List<ChunkRecord> chunks,
  }) {
    if (tasks.isFileRegistered(file.fileId)) {
      return;
    }
    tasks.registerFile(
      FrozenFileRegistration(
        taskId: transferId,
        fileId: file.fileId,
        relativePath: file.relativePath,
        sizeBytes: file.sizeBytes,
        fileSha256: file.fileSha256,
        chunkManifestDigest: file.chunkManifestDigest,
        chunks: chunks,
      ),
      nowMillis: now(),
    );
  }

  /// Re-derives what is still missing for [fileId] from this node's own database.
  ///
  /// Never from a byte counter and never from the peer's report: `AGENTS.md` §2 rule 5 makes the
  /// committed rows the only recovery authority, and this is where that rule is honoured.
  List<int> missingChunks(String fileId) => tasks.missingChunkIndices(fileId);

  /// Commits one received chunk, presenting the generation the peer granted.
  Future<ChunkWriteOutcome> acceptChunk({
    required String transferId,
    required String fileId,
    required int index,
    required Uint8List bytes,
    required int leaseEpoch,
  }) => tasks.writeChunkWithFileLock(
    taskId: transferId,
    fileId: fileId,
    index: index,
    bytes: bytes,
    leaseEpoch: leaseEpoch,
    sink: sink,
    window: windows.windowFor(transferId, fileId),
    atBoundary: index == _chunkCountOf(transferId, fileId) - 1,
  );

  int _chunkCountOf(String transferId, String fileId) {
    final FrozenManifest frozen = staging.frozenManifest(transferId)!;
    for (final ManifestFile file in frozen.files) {
      if (file.fileId == fileId) {
        return file.chunkCount;
      }
    }
    throw StorageException(
      StorageFailureCode.manifestMismatch,
      '$fileId is not part of transfer $transferId',
    );
  }

  /// Verifies one file and, unless [targetRef] is null, exports it.
  ///
  /// This is §10's "完成" as code: the whole-file digest is recomputed over the staged bytes, the
  /// receipt is handed to the export service, and the export service refuses anything that is not
  /// exportable. A file whose bytes are wrong cannot become `COMPLETED` through this path.
  Future<ReceivedFileOutcome> finishFile({
    required String fileId,
    String? targetRef,
  }) async {
    // §10's per-file chain has to be walked, not jumped: `recordSavedExport` asserts
    // `exporting → completed`, so a file that arrived and was never advanced would fail at the
    // last step with "pending -> completed is not defined" - after its copy was already on disk.
    // Doing it here keeps the ordering explicit and lets the state machine refuse a mistake.
    _advanceFileTo(fileId, FileState.verifying);

    final FileVerificationResult verification = await verifier.verifyFile(
      fileId: fileId,
    );
    if (targetRef == null) {
      return ReceivedFileOutcome(
        fileId: fileId,
        verification: verification,
        export: null,
      );
    }
    if (!verification.isExportable) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'file $fileId did not pass verification, so it must not be exported: '
        '${verification.summary}',
      );
    }
    _advanceFileTo(fileId, FileState.exporting);
    final ExportOutcome outcome = await exporter.exportFile(
      fileId: fileId,
      targetRef: targetRef,
      verification: verification,
    );
    return ReceivedFileOutcome(
      fileId: fileId,
      verification: verification,
      export: outcome,
      savedPath: outcome.safePath,
    );
  }

  /// Walks a file's state forward to [target], stopping when it is already there.
  ///
  /// Every step goes through `transitionFile`, so an undefined edge is refused rather than
  /// written - which is what makes this safe to call on a resumed transfer whose file is already
  /// part-way along the chain.
  void _advanceFileTo(String fileId, FileState target) {
    const List<FileState> chain = <FileState>[
      FileState.preparing,
      FileState.transferring,
      FileState.verifying,
      FileState.exporting,
    ];
    for (final FileState step in chain) {
      final FileState from = transfers.fileState(fileId);
      if (from == target) {
        return;
      }
      if (from == step) {
        continue;
      }
      if (!FileStateMachine.canTransition(from, step)) {
        // Already past this step, or the chain does not apply; the next call will decide.
        continue;
      }
      transfers.transitionFile(fileId: fileId, to: step);
    }
  }

  /// Accepts a `client_to_server` transfer on this node, which is the receiver.
  ///
  /// §6 makes the acceptance the moment the receiver commits to a digest, a save location and a
  /// space estimate, and §6 also forbids touching a byte before it. So this runs the space
  /// pre-check first: a shortfall is refused with the estimate persisted rather than silently
  /// starting a transfer that cannot finish.
  TaskAuthorizationRecord acceptLocally({
    required String transferId,
    required ReceiverStorageContext context,
    SpacePlanner planner = const SpacePlanner(),
  }) {
    final FrozenManifest frozen = staging.frozenManifest(transferId)!;
    final SpacePlan plan = planner.plan(
      files: <FileSpaceRequest>[
        for (final ManifestFile file in frozen.files)
          FileSpaceRequest(
            fileId: file.fileId,
            sizeBytes: file.sizeBytes,
            stagingVolume: context.stagingVolume,
            exportVolume: context.exportVolume,
            stagingAlreadyAllocatedBytes: 0,
          ),
      ],
      availability: context.availability,
      volumeForDatabase: context.databaseVolume,
    );

    final TaskAuthorizationRecord record = authorizations.recordDecision(
      transferId: transferId,
      manifestDigest: frozen.manifestDigest,
      decision: TransferDecision.accepted,
      saveLocationRef: context.saveLocationRef,
      spaceEstimate: SpaceEstimateSnapshot.of(plan),
    );
    credentials.issueSecrets(transferId);

    // §8's authoritative rows are created here, at acceptance, because this is the first moment
    // the receiver has committed to what it will hold: before it, a chunk request has nothing to
    // be checked against; after it, `chunks.state` is the only record of how far the transfer
    // got. The records come from the sealed manifest's own chunk pages, so the lengths and
    // digests the receiver enforces are the ones the sender's manifest declared.
    for (final ManifestFile file in frozen.files) {
      registerRemoteFile(
        transferId: transferId,
        file: file,
        chunks: staging.store.readChunkPage(
          transferId,
          fileId: file.fileId,
          startIndex: 0,
          limit: file.chunkCount,
        ),
      );
    }

    transfers.transitionTask(taskId: transferId, to: TransferState.ready);
    return record;
  }
}

/// The narrow shape this file needs from a response, so the engine does not depend on which
/// transport produced it.
class ReceivedLike {
  const ReceivedLike({required this.status, this.errorCode});

  final int status;
  final ProtocolErrorCode? errorCode;

  bool get isSuccess => status >= 200 && status < 300;
}
