import 'package:flutter/foundation.dart';

import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/transfer_resume_request.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/receive_output_plan_repository.dart';
import 'package:nearsend/core/transfer/transfer_client.dart';
import 'package:nearsend/core/transfer/transfer_engine.dart';
import 'package:nearsend/features/transfer/application/transfer_flow.dart';
import 'package:nearsend/features/transfer/application/receive_confirmation.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';

/// The receiving side, from an offer the peer made to a file on this device.
///
/// ## Where the authority sits, and why the order is what it is
///
/// This device is the **receiver**, so §9 makes this device's committed rows the only authority on
/// progress and the peer's rows a mirror. That is why the sequence below is not "download, then
/// write": every chunk is written and committed through [TransferEngine.acceptChunk] **before** the
/// next one is asked for, and what is asked for is derived from this node's own `missing` rows
/// rather than from a byte counter. A restart in the middle therefore resumes from what is on disk,
/// and a chunk that was merely received into memory has never counted.
///
/// ## The two steps that are easy to think of as one
///
/// §6 splits the receiver's decision from the delivery of the credentials, and §9 gives the
/// **sender** the right to allocate the write generation while the receiver persists it. So
/// `decide` → `authorization` → `resume` happens once per transfer, the returned generation is
/// adopted into this device's own row, and only then can a chunk be committed against it.
///
/// ## What it does not do
///
/// It does not decide whether the transfer should be accepted - that is the user's answer, given on
/// the confirmation screen - and it does not choose the save location silently: [accept] takes it as
/// an argument, because the destination is the one thing a receiving user must be able to control.
class ReceivingFlow extends ChangeNotifier {
  ReceivingFlow({
    required this.engine,
    required this.wire,
    required this.now,
    ReceiveOutputPlanRepository? outputPlans,
  }) : outputPlans =
           outputPlans ?? ReceiveOutputPlanRepository(engine.database);

  final TransferEngine engine;
  final TransferClient wire;
  final ReceiveOutputPlanRepository outputPlans;

  /// The clock, injected so a test can state timestamps instead of racing them.
  final int Function() now;

  /// Said when the peer refused to deliver the credentials for an offer this device accepted.
  static const String refusedReason = '对方没有交付这次传输所需的凭据，无法继续。';

  /// Said for anything else, which a user cannot act on beyond trying again.
  static const String failedReason = '接收未能完成：连接可能已中断。已写入的块保留在本机，可继续接收。';

  ReceivePhase _phase = ReceivePhase.idle;
  List<OfferSummary> _offers = const <OfferSummary>[];
  OfferSummary? _offer;
  String? _failureReason;
  TransferFlow? _flow;
  final List<String> _savedPaths = <String>[];
  int _currentIndex = 0;
  int _fileCount = 0;

  ReceivePhase get phase => _phase;

  /// What the peer is offering this session (§6).
  List<OfferSummary> get offers => List<OfferSummary>.unmodifiable(_offers);

  /// The offer being received, when one is.
  OfferSummary? get offer => _offer;

  String? get failureReason => _failureReason;

  /// The figures for the file being received, or null before anything is.
  TransferProgress? get progress => _flow?.progress;

  /// Where the files that were written ended up, in the order they were written.
  List<String> get savedPaths => List<String>.unmodifiable(_savedPaths);

  /// Which file of the transfer is in flight, one-based; 0 when none is.
  int get currentFileNumber => _flow == null ? 0 : _currentIndex + 1;

  int get fileCount => _fileCount;

  /// The name of the file in flight, from the frozen manifest.
  String? get currentFileName =>
      _flow == null || _offer == null ? null : _currentFileNames[_currentIndex];

  final List<String> _currentFileNames = <String>[];
  final Map<String, FrozenManifest> _previewedManifests =
      <String, FrozenManifest>{};

  bool get isBusy =>
      _phase == ReceivePhase.accepting || _phase == ReceivePhase.receiving;

  /// Asks the peer what it is offering, and keeps the list for a screen to show.
  ///
  /// §6 lists offers to the session a transfer is bound to, so this is the receiving device's only
  /// way to learn that something is waiting - there is no push in the protocol.
  Future<List<OfferSummary>> refresh() async {
    if (_disposed) {
      return const <OfferSummary>[];
    }
    try {
      _offers = await wire.offers();
      if (_phase == ReceivePhase.idle || _phase == ReceivePhase.offered) {
        _phase = _offers.isEmpty ? ReceivePhase.idle : ReceivePhase.offered;
        _failureReason = null;
        _notify();
      }
      return _offers;
    } on Object {
      _failureReason = failedReason;
      _phase = ReceivePhase.failed;
      _notify();
      return const <OfferSummary>[];
    }
  }

  Future<List<ReceiveFilePreview>> preview(OfferSummary offer) async {
    final FrozenManifest manifest = await wire.readManifest(offer.transferId);
    _validateOffer(offer, manifest);
    _previewedManifests[offer.transferId] = manifest;
    return <ReceiveFilePreview>[
      for (final ManifestFile file in manifest.files)
        ReceiveFilePreview(
          fileId: file.fileId,
          originalPath: file.relativePath,
          sizeBytes: file.sizeBytes,
        ),
    ];
  }

  /// Accepts [offer] and pulls it to [saveLocationRef].
  ///
  /// [saveLocationRef] is the directory the files are written into, and it is required rather than
  /// defaulted: a receiving transfer whose destination nobody chose is the case §6 keeps the
  /// decision and the location together to prevent.
  Future<bool> accept(
    OfferSummary offer, {
    required String saveLocationRef,
    Map<String, String> outputNames = const <String, String>{},
    void Function(int received, int total)? onFileProgress,
  }) async {
    if (isBusy) {
      return false;
    }
    _offer = offer;
    _failureReason = null;
    _savedPaths.clear();
    _currentFileNames.clear();
    _currentIndex = 0;
    _set(ReceivePhase.accepting);

    try {
      // File metadata is deliberately read before the decision. The session is bound to this task,
      // and §6 requires the receiver to show and persist the exact output mapping before any task
      // credential can make file bytes available.
      final FrozenManifest manifest =
          _previewedManifests.remove(offer.transferId) ??
          await wire.readManifest(offer.transferId);
      _validateOffer(offer, manifest);
      _createOutputPlans(
        transferId: offer.transferId,
        files: manifest.files,
        saveLocationRef: saveLocationRef,
        outputNames: outputNames,
      );

      // §6: the decision is this device's, and it is recorded with the digest it commits to.
      await wire.decide(
        transferId: offer.transferId,
        manifestDigest: offer.manifestDigest,
        accept: true,
      );

      final AuthorizationGrant grant;
      try {
        grant = await wire.fetchAuthorization(transferId: offer.transferId);
      } on Object {
        throw ReceivingRefused(refusedReason);
      }

      // §9: this device is the receiver but the peer allocates the generation, so everything this
      // device has committed so far is reported back and the new generation is adopted locally.
      final ResumeGranted resumed = await wire.resume(
        transferId: offer.transferId,
        manifestDigest: offer.manifestDigest,
        taskResumeSecret: grant.taskResumeSecret,
        receiverState: _receiverState(offer.transferId),
      );

      engine.registerRemoteManifest(offer.transferId, manifest);
      _fileCount = manifest.files.length;
      _set(ReceivePhase.receiving);

      for (int index = 0; index < manifest.files.length; index++) {
        final ManifestFile file = manifest.files[index];
        _currentIndex = index;
        _currentFileNames.add(file.relativePath);
        _flow = TransferFlow.forTotal(
          totalBytes: file.sizeBytes,
          atMillis: now(),
        );
        _notify();

        final List<ChunkRecord> records = await wire.readChunkRecords(
          transferId: offer.transferId,
          file: file,
        );
        engine.registerRemoteFile(
          transferId: offer.transferId,
          file: file,
          chunks: records,
        );
        // §9: the peer allocated the write generation and this device is the receiver, so the
        // generation is adopted into its own row - after the rows exist, because a generation
        // recorded against a task nobody has written yet would be a claim with nothing behind it.
        engine.tasks.adoptLeaseEpoch(
          offer.transferId,
          epoch: resumed.leaseEpoch,
        );

        // Only what this device's own rows say is missing. Never a counter, and never a resumed
        // offset: `AGENTS.md` §2 rule 5 makes the committed rows the only recovery authority.
        final List<int> missing = engine.missingChunks(file.fileId);
        int received = file.chunkCount - missing.length;
        for (final int chunkIndex in missing) {
          final bytes = await wire.getChunk(
            transferId: offer.transferId,
            fileId: file.fileId,
            index: chunkIndex,
            leaseEpoch: resumed.leaseEpoch,
            manifestDigest: offer.manifestDigest,
          );
          await engine.acceptChunk(
            transferId: offer.transferId,
            fileId: file.fileId,
            index: chunkIndex,
            bytes: bytes,
            leaseEpoch: resumed.leaseEpoch,
          );
          received++;
          _flow?.applyChunkAcknowledged(
            acknowledged: received,
            chunkBytes: ProtocolLimits.chunkSizeBytes,
            atMillis: now(),
          );
          onFileProgress?.call(received, file.chunkCount);
          _notify();
        }

        // §10: verification and export happen here, and only a file whose bytes match the frozen
        // manifest reaches the target directory.
        _flow?.applyTaskState(TransferState.verifying, atMillis: now());
        _notify();
        final ReceivedFileOutcome outcome = await _finishPlannedFile(
          transferId: offer.transferId,
          file: file,
        );
        // `!= true` rather than `!`: a verification that could not be computed reports null, and
        // "unknown" must never be treated as "passed" - that is the one path that would put a file
        // of unverified bytes where the user asked for the file itself.
        if (outcome.verification.wholeFileDigestMatches != true) {
          throw ReceivingRefused('${file.relativePath} 的整文件校验未通过，没有保存。');
        }
        final String? savedPath = outcome.savedPath;
        if (savedPath != null) {
          _savedPaths.add(savedPath);
        }
        _flow?.applyCompleted(atMillis: now());
        _notify();

        // §9's mirror and §10's statement: the sender is told how much was committed, and that
        // this device saved the file. Both are reports about *this* device's rows.
        await wire.reportCheckpoint(
          transferId: offer.transferId,
          manifestDigest: offer.manifestDigest,
          leaseEpoch: resumed.leaseEpoch,
          checkpointSeq: engine.tasks.checkpointSeq(offer.transferId),
          committedBytes: engine.tasks.committedBytesForTask(offer.transferId),
        );
        await wire.complete(
          transferId: offer.transferId,
          fileId: file.fileId,
          leaseEpoch: resumed.leaseEpoch,
          saved: true,
          fileSha256: file.fileSha256,
        );
      }

      _set(ReceivePhase.saved);
      return true;
    } on Object catch (error) {
      // The reason a user sees is one of two sentences rather than an exception's text: that text is
      // written for whoever reads logs and may name a path or a document id (`AGENTS.md` §5).
      _failureReason = error is ReceivingRefused ? error.detail : failedReason;
      _flow?.applyFailure(_failureReason!, atMillis: now());
      _set(ReceivePhase.failed);
      return false;
    }
  }

  static void _validateOffer(OfferSummary offer, FrozenManifest manifest) {
    if (manifest.manifestDigest != offer.manifestDigest ||
        manifest.fileCount != offer.fileCount ||
        manifest.totalBytes != offer.totalBytes) {
      throw ReceivingRefused('对方提供的文件清单已经变化，请刷新后重新确认。');
    }
  }

  void _createOutputPlans({
    required String transferId,
    required List<ManifestFile> files,
    required String saveLocationRef,
    required Map<String, String> outputNames,
  }) {
    final Set<String> offeredIds = <String>{
      for (final ManifestFile file in files) file.fileId,
    };
    if (!offeredIds.containsAll(outputNames.keys)) {
      throw ArgumentError.value(
        outputNames.keys
            .where((String id) => !offeredIds.contains(id))
            .toList(),
        'outputNames',
        'contains a file that is not in the frozen manifest',
      );
    }
    outputPlans.create(
      transferId: transferId,
      targetRef: saveLocationRef,
      choices: <ReceiveOutputChoice>[
        for (final ManifestFile file in files)
          ReceiveOutputChoice(
            fileId: file.fileId,
            originalPath: file.relativePath,
            selectedName:
                outputNames[file.fileId] ?? _fileNameOf(file.relativePath),
          ),
      ],
    );
  }

  Future<ReceivedFileOutcome> _finishPlannedFile({
    required String transferId,
    required ManifestFile file,
  }) async {
    final ReceiveOutputPlan plan = outputPlans.read(transferId, file.fileId)!;
    outputPlans.markExporting(transferId, file.fileId);
    try {
      final ReceivedFileOutcome outcome = await engine.finishFile(
        fileId: file.fileId,
        targetRef: plan.targetRef,
        outputName: plan.selectedName,
        conflictPolicy: plan.conflictPolicy,
      );
      final export = outcome.export;
      if (export == null || !export.isSaved || outcome.savedPath == null) {
        outputPlans.markFailed(transferId, file.fileId);
        throw ReceivingRefused('${file.relativePath} 未能保存，暂存内容已保留，可重试。');
      }
      outputPlans.markSaved(
        transferId: transferId,
        fileId: file.fileId,
        finalName: outcome.savedPath!,
        finalTargetRef: export.createdTargetRef,
      );
      return outcome;
    } on Object {
      final ReceiveOutputPlan? current = outputPlans.read(
        transferId,
        file.fileId,
      );
      if (current?.state == ReceiveOutputState.exporting) {
        outputPlans.markFailed(transferId, file.fileId);
      }
      rethrow;
    }
  }

  static String _fileNameOf(String relativePath) =>
      relativePath.substring(relativePath.lastIndexOf('/') + 1);

  /// What this device has committed for the transfer, from its own rows.
  ///
  /// Zero for a transfer it has never seen, which is exactly what §9 wants a fresh receiver to
  /// report: an invented figure would be this device claiming progress it cannot show.
  ReceiverState _receiverState(String transferId) {
    try {
      return ReceiverState(
        leaseEpoch: engine.tasks.leaseEpoch(transferId),
        checkpointSeq: engine.tasks.checkpointSeq(transferId),
        committedBytes: engine.tasks.committedBytesForTask(transferId),
      );
    } on Object {
      return const ReceiverState(
        leaseEpoch: 0,
        checkpointSeq: 0,
        committedBytes: 0,
      );
    }
  }

  void _set(ReceivePhase phase) {
    _phase = phase;
    _notify();
  }

  void _notify() {
    // A screen's poll can outlive the flow it asks by a frame - the timer is cancelled when the page
    // is disposed, which is not necessarily before the flow it was given. Notifying then would be a
    // crash in debug and a silent no-op in release, so it is refused in both the same way.
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  bool _disposed = false;
}

/// Where a receiving flow is.
enum ReceivePhase {
  /// Nothing has been offered to this session.
  idle,

  /// The peer is offering something and nobody has answered.
  offered,

  /// The offer was accepted and the credentials are being fetched.
  accepting,

  /// Chunks are being written and committed.
  receiving,

  /// Every file was verified against the frozen manifest and saved.
  saved,

  /// Stopped, with a reason the user can act on.
  failed,
}

/// A refusal raised by this layer rather than by the protocol.
class ReceivingRefused implements Exception {
  ReceivingRefused(this.detail);

  final String detail;

  @override
  String toString() => 'ReceivingRefused($detail)';
}
