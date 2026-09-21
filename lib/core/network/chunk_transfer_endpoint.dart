/// §8's chunk `PUT` and `GET`: the data plane.
///
/// ## Why one class serves both directions
///
/// §7 gives the two endpoints opposite directions - `PUT` is "仅 client_to_server" and `GET` is
/// "仅 server_to_client" - but they are the same conversation seen from two sides, and §8's
/// rules about which side owns which fact apply to both. Keeping them together means the
/// generation check, the manifest check and the length check are written once and cannot drift
/// apart for the two directions.
///
/// ## The write path, in §8's order
///
/// §8:
///
/// > 写入顺序：认证和授权→文件锁→再次检查 epoch→写入并验证长度/块摘要→受控待提交队列→`syncData`
/// > →SQLite 事务提交块标志和 `checkpointSeq`→发布 committed。
///
/// Authentication is the pipeline's stage and has already run. What is left - the file lock, the
/// generation re-check, the durable write, the bounded pending window and the transactional
/// commit - is `ChunkRepository.writeChunkWithFileLock`, which is where §8's ordering was
/// implemented and tested. This class adds only what needs the wire: reading §8's headers,
/// checking the declared body against the frozen manifest, and turning the outcome into §8's
/// `verified_pending` or `committed` answer.
///
/// ## A re-sent chunk is verified, not accepted
///
/// §8: "重复已提交块必须校验世代、长度和内容；内容冲突返回 `CHUNK_HASH_MISMATCH`，**不可因「已有块」就
/// 无条件成功**". The repository re-checks every receipt against the frozen manifest inside the
/// commit transaction, so an already-committed index still has to match. This class checks the
/// declared length before anything is written, so a body of the wrong size never reaches disk.
///
/// ## What `GET` does not promise
///
/// §7: "下载成功不代表接收端持久化". Serving a chunk says the sender produced the bytes; it says
/// nothing about the receiver having stored them, and the receiver's own committed rows remain
/// the only authority for that.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:nearsend/core/network/control_authorization.dart';
import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/network/control_pipeline.dart';
import 'package:nearsend/core/network/manifest_staging_registry.dart';
import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/chunk_headers.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/commit_window.dart';
import 'package:nearsend/core/storage/storage_failure.dart';

/// A source whose bytes can be streamed for a chunk `GET`.
///
/// A port rather than a `File`, because a desktop path and a SAF URI are not the same thing and
/// `AGENTS.md` §9 forbids assuming they are. The chunk is read whole because §8 defines a chunk
/// as the unit, but nothing larger than one chunk is ever held.
abstract class OutgoingChunkSource {
  /// Reads exactly [length] bytes at [offset] of [fileId].
  ///
  /// Throws [StorageException] with [StorageFailureCode.manifestMismatch] when the source does
  /// not have them.
  Future<Uint8List> readChunk({
    required String transferId,
    required String fileId,
    required int offsetBytes,
    required int length,
  });
}

/// The per-file pending-commit windows §8 allows.
///
/// §8 bounds "最多 16 MiB 待持久化有效数据" per file, so the window is keyed by file rather than by
/// task. It lives in memory **deliberately**: the window is a batching device whose whole point
/// is that a crash between commits loses the batch and the chunks stay `missing`, so persisting
/// it would be persisting something the protocol says is not progress.
class ChunkWindowRegistry {
  ChunkWindowRegistry({
    required this.tasks,
    this.policy = const CommitWindowPolicy(),
  });

  /// The repository that owns the only path which marks a chunk committed.
  ///
  /// Held rather than passed per call so a forced checkpoint cannot be attempted without one:
  /// a pause that could not commit would drop verified work that §8 says must be preserved.
  final ChunkRepository tasks;

  final CommitWindowPolicy policy;

  final Map<String, ChunkCommitWindow> _windows = <String, ChunkCommitWindow>{};

  /// The window for one file of one task, created on first use.
  ChunkCommitWindow windowFor(String taskId, String fileId) =>
      _windows[_key(taskId, fileId)] ??= ChunkCommitWindow(policy: policy);

  /// Forgets a file's window after its last chunk.
  void release(String taskId, String fileId) =>
      _windows.remove(_key(taskId, fileId));

  /// Commits every pending receipt of a task's open windows: §8's forced checkpoint at a pause.
  ///
  /// §8: "暂停/文件结尾强制提交". A file end is handled per chunk by
  /// [ChunkTransferEndpoint.putChunk]'s boundary flag; a pause affects every file of the task, so
  /// it needs the whole set. A window with nothing pending is dropped rather than committed, so a
  /// pause cannot advance a sequence that records no work.
  void flushTask(String taskId, {required int leaseEpoch}) {
    final String prefix = '$taskId\u0000';
    final List<String> keys = _windows.keys
        .where((String key) => key.startsWith(prefix))
        .toList();
    for (final String key in keys) {
      final ChunkCommitWindow window = _windows[key]!;
      if (window.hasPending) {
        tasks.commitPendingBatch(
          taskId: taskId,
          fileId: key.substring(prefix.length),
          leaseEpoch: leaseEpoch,
          window: window,
        );
      }
      _windows.remove(key);
    }
  }

  /// Forgets every window of a task.
  void releaseTask(String taskId) {
    _windows.removeWhere((String key, _) => key.startsWith('$taskId\u0000'));
  }

  /// How many windows are held, for a bounded-buffer assertion.
  int get openWindowCount => _windows.length;

  static String _key(String taskId, String fileId) => '$taskId\u0000$fileId';
}

/// The `PUT` and `GET` chunk use cases.
class ChunkTransferEndpoint {
  ChunkTransferEndpoint({
    required this.tasks,
    required this.staging,
    required this.windows,
    required this.sink,
    this.source,
  });

  /// §8's write ordering and the resumable-progress authority.
  final ChunkRepository tasks;

  /// The frozen manifest, which is the authority for every chunk's length and digest.
  final ManifestStagingRegistry staging;

  /// The bounded pending-commit windows.
  final ChunkWindowRegistry windows;

  /// The platform port that writes and durably syncs staged bytes.
  final DurableChunkSink sink;

  /// The platform port that produces a sender's bytes for a chunk `GET`.
  final OutgoingChunkSource? source;

  /// `PUT /transfers/{id}/files/{fid}/chunks/{index}`.
  Future<ControlResponse> putChunk({
    required String transferId,
    required String fileId,
    required int index,
    required Map<String, String> headers,
    required Uint8List body,
  }) async {
    // §8 parses and validates every framing rule before a byte is looked at.
    final ChunkPutHeaders parsed = ChunkPutHeaders.parse(headers);

    final FrozenManifest frozen = _frozen(transferId);
    if (parsed.manifestDigest != frozen.manifestDigest) {
      throw const ProtocolViolation(
        ProtocolErrorCode.manifestMismatch,
        'the chunk names a manifest this task was not sealed with',
      );
    }

    final int expected = _expectedChunkLength(frozen, fileId, index);
    if (parsed.contentLength != expected) {
      // §8's declared-length rule, applied before the body is considered: a body whose size
      // the peer got wrong is not a chunk to hash and compare, it is a framing disagreement.
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'chunk $index declares ${parsed.contentLength} bytes but the frozen manifest '
        'requires $expected',
      );
    }
    if (body.length != expected) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'chunk $index arrived with ${body.length} bytes but the frozen manifest '
        'requires $expected',
      );
    }

    final ChunkWriteOutcome outcome = await tasks.writeChunkWithFileLock(
      taskId: transferId,
      fileId: fileId,
      index: index,
      bytes: body,
      leaseEpoch: parsed.leaseEpoch,
      sink: sink,
      window: windows.windowFor(transferId, fileId),
      // §8 forces a checkpoint at a file's last chunk; the file's end is knowable here from
      // the frozen manifest, and §8 also requires one at a pause, which the pause endpoint
      // performs by flushing the same window.
      atBoundary: index == _chunkCount(frozen, fileId) - 1,
    );

    return ControlResponse.json(
      status: outcome.state == ChunkWriteState.committed ? 200 : 202,
      body: ChunkWriteResult(
        index: outcome.index,
        state: outcome.state,
        leaseEpoch: outcome.leaseEpoch,
        checkpointSeq: outcome.checkpointSeq,
      ).toJson(),
    );
  }

  /// `GET /transfers/{id}/files/{fid}/chunks/{index}`.
  Future<ControlResponse> getChunk({
    required String transferId,
    required String fileId,
    required int index,
    required Map<String, String> headers,
  }) async {
    final OutgoingChunkSource? reader = source;
    if (reader == null) {
      // Refused rather than answered with an empty body: a sender that cannot read its own
      // source must not look like a transfer that is going fine.
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidState,
        'this server has no source for outbound chunks',
      );
    }

    final ChunkGetRequestHeaders parsed = ChunkGetRequestHeaders.parse(headers);
    final FrozenManifest frozen = _frozen(transferId);
    if (parsed.manifestDigest != frozen.manifestDigest) {
      throw const ProtocolViolation(
        ProtocolErrorCode.manifestMismatch,
        'the request names a manifest this task was not sealed with',
      );
    }
    final int currentEpoch = tasks.leaseEpoch(transferId);
    if (parsed.leaseEpoch != currentEpoch) {
      throw ProtocolViolation(
        ProtocolErrorCode.staleLease,
        'write generation ${parsed.leaseEpoch} is not current ($currentEpoch)',
      );
    }

    final int length = _expectedChunkLength(frozen, fileId, index);
    final int offset = chunkOffsetForIndex(
      _sizeOf(frozen, fileId),
      frozen.files.first.chunkSizeBytes,
      index,
    );
    final Uint8List bytes = await reader.readChunk(
      transferId: transferId,
      fileId: fileId,
      offsetBytes: offset,
      length: length,
    );
    if (bytes.length != length) {
      throw ProtocolViolation(
        ProtocolErrorCode.sourceChanged,
        'the source produced ${bytes.length} bytes for chunk $index but the frozen '
        'manifest requires $length',
      );
    }

    // §8: `GET` returns the length and the digest; the receiver still treats the frozen manifest
    // as authoritative, so this header is a reference and not a claim the receiver must accept.
    return ControlResponse.binary(
      status: 200,
      body: bytes,
      headers: <String, String>{
        chunkSha256Header: sha256.convert(bytes).toString(),
      },
    );
  }

  /// The pipeline closures for the two chunk routes.
  Map<String, ControlHandler> handlers() => <String, ControlHandler>{
    ApiRoutes.putChunk.name:
        (
          ControlRequest request,
          MatchedApiRequest matched,
          ControlAuthorized authorization,
        ) async => putChunk(
          transferId: _require(matched.transferId, 'transfer id'),
          fileId: _require(matched.fileId, 'file id'),
          index: _requireIndex(matched),
          headers: request.headers,
          body: request.body,
        ),
    ApiRoutes.getChunk.name:
        (
          ControlRequest request,
          MatchedApiRequest matched,
          ControlAuthorized authorization,
        ) async => getChunk(
          transferId: _require(matched.transferId, 'transfer id'),
          fileId: _require(matched.fileId, 'file id'),
          index: _requireIndex(matched),
          headers: request.headers,
        ),
  };

  FrozenManifest _frozen(String transferId) {
    final FrozenManifest? frozen = staging.frozenManifest(transferId);
    if (frozen == null) {
      // §6: nothing may be transferred before the manifest is frozen and the receiver has
      // accepted, and an unfrozen manifest is exactly that condition.
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidState,
        'the transfer has no frozen manifest, so no chunk of it can be transferred',
      );
    }
    return frozen;
  }

  static int _expectedChunkLength(
    FrozenManifest frozen,
    String fileId,
    int index,
  ) {
    final ManifestFile file = _fileOf(frozen, fileId);
    if (index < 0 || index >= file.chunkCount) {
      throw ProtocolViolation(
        ProtocolErrorCode.notFound,
        'chunk $index is outside 0..${file.chunkCount - 1} for this file',
      );
    }
    return chunkLengthForIndex(file.sizeBytes, file.chunkSizeBytes, index);
  }

  static int _chunkCount(FrozenManifest frozen, String fileId) =>
      _fileOf(frozen, fileId).chunkCount;

  static int _sizeOf(FrozenManifest frozen, String fileId) =>
      _fileOf(frozen, fileId).sizeBytes;

  static ManifestFile _fileOf(FrozenManifest frozen, String fileId) {
    for (final ManifestFile file in frozen.files) {
      if (file.fileId == fileId) {
        return file;
      }
    }
    // §7's uniform answer for a resource that is not part of the authorised manifest: the file
    // may not exist at all, and saying which would confirm what the manifest holds.
    throw const ProtocolViolation(
      ProtocolErrorCode.notFound,
      'no file with that id is part of this transfer',
    );
  }

  static int _requireIndex(MatchedApiRequest matched) {
    final int? index = matched.chunkIndex;
    if (index == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.notFound,
        'the route carries no chunk index',
      );
    }
    return index;
  }

  static String _require(String? value, String what) {
    if (value == null) {
      throw ProtocolViolation(
        ProtocolErrorCode.notFound,
        'the route carries no $what',
      );
    }
    return value;
  }
}
