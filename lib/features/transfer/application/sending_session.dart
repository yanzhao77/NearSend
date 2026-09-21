import 'dart:typed_data';

import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';
import 'package:nearsend/core/storage/local_file_layer.dart';
import 'package:nearsend/core/transfer/transfer_client.dart';
import 'package:nearsend/core/transfer/transfer_engine.dart';

/// The sending side of a transfer, as the sequence §6 to §10 prescribes.
///
/// ## Why this exists
///
/// Every step of a client-to-server transfer was implemented and tested, and nothing called them in
/// order. That is the difference between a working protocol and a working product, and it is the
/// last piece the UI needed: the selection screen can now produce choices, and this turns choices
/// into bytes at the receiver.
///
/// ## The order, and why each step cannot be skipped
///
/// 1. **plan** - §5.2's and §5.3's digests are computed over the source, so the manifest has to
///    exist before anything can be declared. This reads the whole source once, in bounded pieces.
/// 2. **propose** - §6: create the staging transfer, upload its pages, seal it. Only a sealed
///    manifest may be offered, and §7 refuses a chunk before that.
/// 3. **accept** - the receiver's own decision. Nothing here may move a byte first: §6 forbids
///    processing file bytes before acceptance, and the gate is a write generation that does not
///    exist until step 4.
/// 4. **openWriteGeneration** - §3 delivers the resume secret, §9 allocates the generation. Skipping
///    it would leave every chunk presenting generation 0, which §8 refuses as stale.
/// 5. **send** - §8's chunk transport, one chunk at a time with the consumer awaited first.
///
/// ## What it does not do
///
/// It does not decide, accept or export. Those belong to the receiving node, and on a device they
/// are the user's actions - so this class deliberately has no method that could perform them
/// locally and give a caller the impression a transfer completed without the other side agreeing.
class SendingSession {
  const SendingSession({
    required this.engine,
    required this.wire,
    this.transferId,
  });

  final TransferEngine engine;
  final TransferClient wire;

  /// The transfer this session works on, when it has been chosen.
  final String? transferId;

  /// Plans the chosen sources and stages their manifest, stopping at `WAITING_ACCEPT`.
  Future<OutgoingPlan> plan({
    required String transferId,
    required List<OutgoingFileChoice> choices,
    TransferDirection direction = TransferDirection.clientToServer,
  }) => engine.prepareOutgoing(
    transferId: transferId,
    direction: direction,
    choices: choices,
  );

  /// Creates the transfer on the peer, uploads the manifest and seals it (§6).
  ///
  /// The pages come from the plan that built the manifest, so the digest the peer verifies against
  /// and the bytes described by the pages are the same by construction.
  Future<void> propose(OutgoingPlan plan) async {
    await wire.createTransfer(
      transferId: plan.transferId,
      manifestDigest: plan.manifestDigest,
      fileCount: plan.manifest.fileCount,
      totalBytes: plan.manifest.totalBytes,
    );
    await wire.uploadManifest(
      transferId: plan.transferId,
      manifest: plan.manifest,
      pages: engine.pagesFor(plan.manifest, plan.files),
    );
    await wire.seal(
      transferId: plan.transferId,
      manifestDigest: plan.manifestDigest,
    );
  }

  /// Fetches the recovery secret and allocates a write generation (§3, §9).
  ///
  /// This is the first moment a chunk could be accepted, which is why every send path goes through
  /// it rather than presenting a task token from somewhere else.
  Future<ResumeGranted> openWriteGeneration(OutgoingPlan plan) async {
    final AuthorizationGrant grant = await wire.fetchAuthorization(
      transferId: plan.transferId,
    );
    return wire.resume(
      transferId: plan.transferId,
      manifestDigest: plan.manifestDigest,
      taskResumeSecret: grant.taskResumeSecret,
    );
  }

  /// Streams one file's chunks, returning how many the peer acknowledged.
  ///
  /// The count is what the **peer accepted**, not what the receiver has committed: §9 makes the
  /// receiver's rows the only authority on progress, and this side holds a mirror. Reporting it as
  /// committed would be the sender inventing the receiver's state.
  Future<int> sendFile({
    required OutgoingPlan plan,
    required ResumeGranted granted,
    required String fileId,
    Iterable<int>? onlyIndices,
    void Function(int acknowledged, int totalChunks)? onProgress,
  }) async {
    final SourceFilePlan sourcePlan = engine.planFor(plan.transferId, fileId);
    final int total = sourcePlan.chunks.length;
    int acknowledged = 0;

    final int sent = await engine.sendFile(
      transferId: plan.transferId,
      fileId: fileId,
      leaseEpoch: granted.leaseEpoch,
      manifestDigest: plan.manifestDigest,
      taskAccessToken: granted.taskAccessToken,
      onlyIndices: onlyIndices,
      send: (int index, Uint8List bytes) async {
        final ChunkWriteResult result = await wire.putChunk(
          transferId: plan.transferId,
          fileId: fileId,
          index: index,
          bytes: bytes,
          leaseEpoch: granted.leaseEpoch,
          manifestDigest: plan.manifestDigest,
        );
        acknowledged++;
        onProgress?.call(acknowledged, total);
        return ReceivedLike(
          status: result.state == ChunkWriteState.committed ? 200 : 202,
        );
      },
    );
    return sent;
  }

  /// Runs the whole sequence for one file, which is what a caller with nothing to resume wants.
  ///
  /// The steps stay separately callable above so a resumed transfer can skip the proposal - its
  /// manifest is already sealed - and send only the chunks its own rows say are missing.
  Future<int> send(
    OutgoingPlan plan, {
    required String fileId,
    Iterable<int>? onlyIndices,
    void Function(int acknowledged, int totalChunks)? onProgress,
  }) async {
    await propose(plan);
    final ResumeGranted granted = await openWriteGeneration(plan);
    return sendFile(
      plan: plan,
      granted: granted,
      fileId: fileId,
      onlyIndices: onlyIndices,
      onProgress: onProgress,
    );
  }
}
