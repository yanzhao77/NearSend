/// The chunk repository: the receiver's authority on resumable progress.
///
/// `AGENTS.md` §2 rules 5 to 7 and protocol §8 define what this class must guarantee:
///
/// * a **committed** chunk in SQLite is the only evidence of progress. Nothing here
///   exposes a byte counter, because a byte counter is exactly what a recovery path must
///   not trust.
/// * the order is `write → chunk digest → durable sync → commit → acknowledge`. The only
///   method that commits a chunk, [ChunkRepository.commitPendingBatch], requires a
///   verified sync receipt for every chunk it commits, so there is no API that lets a
///   caller commit first and sync later.
/// * a failure at any step must not acknowledge the chunk, so a failed commit leaves the
///   row `missing` and the chunk is re-sent rather than trusted.
/// * a commit is refused unless it presents the task's current write generation, and the
///   generation is re-checked inside the same transaction that commits the chunk - §8
///   warns that checking only at the request entry point lets an in-flight write land
///   after a resume has taken over.
/// * §8 bounds how much verified-but-uncommitted data may accumulate
///   ([ChunkCommitWindow]) and commits a checkpoint sequence with the chunk flags, in the
///   same transaction, so the two can never disagree about how far the receiver got.
library;

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/storage/commit_window.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_failure.dart';
import 'package:nearsend/core/storage/storage_schema.dart';

/// Whether a chunk's bytes are durably committed.
enum ChunkState {
  /// Not committed. The bytes may or may not be on disk; neither is progress.
  missing,

  /// Written, digest-verified, durably synced and committed in a transaction.
  committed;

  static ChunkState fromColumn(String value) => switch (value) {
    'missing' => ChunkState.missing,
    'committed' => ChunkState.committed,
    _ => throw StorageException(
      StorageFailureCode.commitFailed,
      'unknown chunk state "$value" in the database',
    ),
  };

  String get column => name;
}

/// A chunk row as stored.
class StoredChunk {
  const StoredChunk({
    required this.fileId,
    required this.index,
    required this.offsetBytes,
    required this.lengthBytes,
    required this.sha256,
    required this.state,
  });

  final String fileId;
  final int index;
  final int offsetBytes;
  final int lengthBytes;
  final String sha256;
  final ChunkState state;

  @override
  String toString() =>
      'StoredChunk($fileId[$index] ${state.name} $offsetBytes+$lengthBytes)';
}

/// What a sink reports after writing and syncing a chunk.
///
/// The sink is the platform boundary. It is required to have durably synced before it
/// returns; the repository then checks the reported length and digest against the frozen
/// manifest, so a sink that writes the wrong bytes cannot cause a commit even if it
/// reports success.
class DurableChunkWriteResult {
  const DurableChunkWriteResult({
    required this.lengthBytes,
    required this.sha256,
  });

  final int lengthBytes;

  /// Lowercase hexadecimal SHA-256 of the bytes that were synced.
  final String sha256;
}

/// The outcome of one chunk write, in §8's own vocabulary.
///
/// Reuses [ChunkWriteState] rather than declaring a parallel enum: §8 fixes the two wire
/// values, and a second spelling of them is exactly the kind of divergence between the
/// protocol layer and the storage layer that a test on either side alone would miss.
class ChunkWriteOutcome {
  const ChunkWriteOutcome({
    required this.index,
    required this.state,
    required this.leaseEpoch,
    required this.checkpointSeq,
  });

  final int index;
  final ChunkWriteState state;
  final int leaseEpoch;

  /// The sequence of the last committed checkpoint.
  ///
  /// For a [ChunkWriteState.verifiedPending] outcome this is the *previous* checkpoint: the
  /// chunk's bytes are synced but no checkpoint includes them yet.
  final int checkpointSeq;

  @override
  String toString() =>
      'ChunkWriteOutcome($index ${state.wireValue} epoch $leaseEpoch seq '
      '$checkpointSeq)';
}

/// What one batch commit did.
class ChunkBatchCommit {
  const ChunkBatchCommit({
    required this.checkpointSeq,
    required this.committedIndices,
  });

  /// The sequence the checkpoint advanced to, or the unchanged sequence for an empty batch.
  final int checkpointSeq;

  /// The chunk indices this commit marked committed, ascending as the window held them.
  final List<int> committedIndices;

  @override
  String toString() =>
      'ChunkBatchCommit(seq $checkpointSeq, $committedIndices)';
}

/// The platform port that writes chunk bytes and makes them durable.
///
/// Implementations must not return until the bytes are durably synced. Real durable-sync
/// semantics per platform are verified by B04 on real devices; on a filesystem an
/// implementation performs a flush and an `fsync` of both the file and, where the
/// platform requires it, its directory entry.
abstract class DurableChunkSink {
  /// Writes, digest-verifies and durably syncs one chunk.
  ///
  /// Throws [StorageException] with [StorageFailureCode.commitFailed] if any step fails.
  Future<DurableChunkWriteResult> writeVerifyAndSync({
    required String fileId,
    required int index,
    required int offsetBytes,
    required Uint8List bytes,
  });
}

/// The frozen facts about one file, taken from the accepted manifest.
class FrozenFileRegistration {
  const FrozenFileRegistration({
    required this.taskId,
    required this.fileId,
    required this.relativePath,
    required this.sizeBytes,
    required this.fileSha256,
    required this.chunkManifestDigest,
    required this.chunks,
    this.chunkSizeBytes = ProtocolLimits.chunkSizeBytes,
  });

  final String taskId;
  final String fileId;
  final String relativePath;
  final int sizeBytes;
  final String fileSha256;
  final String chunkManifestDigest;

  /// The chunk manifest accepted for this file; supplies each chunk's length and digest.
  final List<ChunkRecord> chunks;

  final int chunkSizeBytes;
}

/// Reads and writes resumable progress for one database.
class ChunkRepository {
  ChunkRepository(this.database);

  final NearSendDatabase database;

  /// §8's checkpoint counter, on `tasks` because that is where its partner `lease_epoch`
  /// lives.
  static const String checkpointSeqColumn =
      StorageSchema.tasksCheckpointSeqColumn;

  /// Registers a task row, or leaves an existing one untouched.
  ///
  /// `lease_epoch` starts at 0, meaning no write generation exists yet: nothing may be
  /// committed until a resume allocates one.
  void registerTask({
    required String taskId,
    required String role,
    required String direction,
    required String state,
    required int protocolMajor,
    required int protocolMinor,
    String? manifestDigest,
    int? nowMillis,
  }) {
    final int now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    database.transaction(() {
      database.db.execute(
        'INSERT INTO tasks (task_id, role, direction, state, protocol_major, '
        'protocol_minor, lease_epoch, manifest_digest, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?) '
        'ON CONFLICT(task_id) DO NOTHING;',
        <Object?>[
          taskId,
          role,
          direction,
          state,
          protocolMajor,
          protocolMinor,
          manifestDigest,
          now,
          now,
        ],
      );
    });
  }

  /// Registers a file and every one of its chunks as `missing`.
  ///
  /// The expected offset, length and digest of each chunk come from the frozen manifest,
  /// never from the peer's claim, so a later comparison has something authoritative to
  /// compare against.
  void registerFile(FrozenFileRegistration registration, {int? nowMillis}) {
    final int expectedCount = chunkCountForSize(
      registration.sizeBytes,
      registration.chunkSizeBytes,
    );
    if (registration.chunks.length != expectedCount) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'file ${registration.fileId} declares ${registration.chunks.length} chunks but '
        'its size requires $expectedCount',
      );
    }

    final int now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    database.transaction(() {
      database.db.execute(
        'INSERT INTO files (file_id, task_id, relative_path, size_bytes, '
        'chunk_size_bytes, chunk_count, file_sha256, chunk_manifest_digest, '
        'export_state, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
        <Object?>[
          registration.fileId,
          registration.taskId,
          registration.relativePath,
          registration.sizeBytes,
          registration.chunkSizeBytes,
          expectedCount,
          registration.fileSha256,
          registration.chunkManifestDigest,
          'pending',
          now,
        ],
      );

      final PreparedStatement insert = database.db.prepare(
        'INSERT INTO chunks (file_id, idx, offset_bytes, length_bytes, sha256, '
        "state, committed_at) VALUES (?, ?, ?, ?, ?, 'missing', NULL);",
      );
      try {
        for (final ChunkRecord chunk in registration.chunks) {
          insert.execute(<Object?>[
            registration.fileId,
            chunk.index,
            chunkOffsetForIndex(
              registration.sizeBytes,
              registration.chunkSizeBytes,
              chunk.index,
            ),
            chunk.length,
            chunk.sha256,
          ]);
        }
      } finally {
        insert.close();
      }
    });
  }

  /// The task's current write generation.
  int leaseEpoch(String taskId) {
    final ResultSet rows = database.db.select(
      'SELECT lease_epoch FROM tasks WHERE task_id = ?;',
      <Object?>[taskId],
    );
    if (rows.isEmpty) {
      throw StorageException(
        StorageFailureCode.staleLease,
        'task $taskId is not registered',
      );
    }
    return rows.first['lease_epoch'] as int;
  }

  /// Revokes the current generation and allocates the next one.
  ///
  /// §8 requires the caller to have cancelled the previous session and waited for its
  /// writes to stop first. Returns the new generation.
  int revokeAndAdvanceLease(String taskId, {int? nowMillis}) {
    final int now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    return database.transaction(() {
      database.db.execute(
        'UPDATE tasks SET lease_epoch = lease_epoch + 1, updated_at = ? '
        'WHERE task_id = ?;',
        <Object?>[now, taskId],
      );
      final int updated = database.db.updatedRows;
      if (updated == 0) {
        throw StorageException(
          StorageFailureCode.staleLease,
          'task $taskId is not registered',
        );
      }
      return leaseEpoch(taskId);
    });
  }

  /// Writes, verifies, durably syncs and commits one chunk (the single-chunk path).
  ///
  /// This is §8's per-chunk checkpoint, expressed as [CommitWindowPolicy.immediate]: it
  /// exists so the one-chunk case is *implemented by* the window rather than beside it.
  /// Callers handling a stream of chunks use [writeChunkThroughWindow] with a shared
  /// window instead, which lets §8 batch the commits.
  ///
  /// The reported length and digest are checked against the frozen manifest before the
  /// commit, so a sink that writes the wrong bytes fails the operation rather than
  /// recording false progress.
  ///
  /// [leaseEpoch] must be the task's current generation. It is checked before the write
  /// and again inside the commit transaction, because §8 warns that a generation can be
  /// superseded while a write is in flight.
  Future<StoredChunk> commitChunkAfterSync({
    required String taskId,
    required String fileId,
    required int index,
    required Uint8List bytes,
    required int leaseEpoch,
    required DurableChunkSink sink,
    int? nowMillis,
  }) async {
    final ChunkCommitWindow window = ChunkCommitWindow(
      policy: CommitWindowPolicy.immediate,
    );
    final ChunkWriteOutcome outcome = await writeChunkThroughWindow(
      taskId: taskId,
      fileId: fileId,
      index: index,
      bytes: bytes,
      leaseEpoch: leaseEpoch,
      sink: sink,
      window: window,
      nowMillis: nowMillis,
      // The single-chunk path has no later boundary to rely on, so the checkpoint it
      // promises is the one it takes now.
      atBoundary: true,
    );
    if (outcome.state != ChunkWriteState.committed) {
      throw StorageException(
        StorageFailureCode.commitFailed,
        'the immediate window left $fileId[$index] verified but uncommitted',
      );
    }
    return readChunk(fileId, index);
  }

  /// Writes, verifies and durably syncs one chunk, then checkpoints the window if §8
  /// requires it.
  ///
  /// This is §8's write path minus the two steps that belong to the endpoint layer:
  /// authentication/authorization and the per-file lock ("认证和授权→文件锁→再次检查 epoch→
  /// 写入并验证长度/块摘要→受控待提交队列→syncData→SQLite 事务提交块标志和 checkpointSeq→
  /// 发布 committed").
  ///
  /// The answer distinguishes §8's two states honestly. A chunk whose bytes are synced but
  /// whose checkpoint has not run yet is `verified_pending`: §8 says that state "只证明本次块
  /// 长度/摘要正确，不可释放持久化确认跟踪", so the returned `checkpointSeq` is the last
  /// committed one and does not include this chunk.
  ///
  /// [atBoundary] reports a pause or a file end, where §8 forces a checkpoint.
  Future<ChunkWriteOutcome> writeChunkThroughWindow({
    required String taskId,
    required String fileId,
    required int index,
    required Uint8List bytes,
    required int leaseEpoch,
    required DurableChunkSink sink,
    required ChunkCommitWindow window,
    int? nowMillis,
    bool atBoundary = false,
  }) async {
    final StoredChunk expected = readChunk(fileId, index);
    final int now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;

    _assertLease(taskId, leaseEpoch);

    if (bytes.length != expected.lengthBytes) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'chunk $fileId[$index] received ${bytes.length} bytes but the frozen manifest '
        'requires ${expected.lengthBytes}',
      );
    }

    // §8 bounds the pending window, so a window that cannot hold this chunk commits what
    // it already has *before* the write rather than exceeding the bound.
    if (window
        .plan(lengthBytes: expected.lengthBytes, nowMillis: now)
        .flushBefore) {
      commitPendingBatch(
        taskId: taskId,
        fileId: fileId,
        leaseEpoch: leaseEpoch,
        window: window,
        nowMillis: now,
      );
    }

    // The sink writes, digest-verifies and durably syncs. If this throws, nothing is
    // committed and the chunk stays missing, so it will be re-sent rather than trusted.
    final DurableChunkWriteResult result = await sink.writeVerifyAndSync(
      fileId: fileId,
      index: index,
      offsetBytes: expected.offsetBytes,
      bytes: bytes,
    );

    if (result.lengthBytes != expected.lengthBytes ||
        result.sha256.toLowerCase() != expected.sha256.toLowerCase()) {
      throw StorageException(
        StorageFailureCode.syncReceiptMismatch,
        'the sink reported ${result.lengthBytes} bytes / ${result.sha256} for '
        '$fileId[$index], which does not match the frozen manifest',
      );
    }

    window.enqueue(
      PendingChunkCommit(
        index: index,
        lengthBytes: result.lengthBytes,
        sha256: result.sha256,
      ),
      nowMillis: now,
    );

    final bool due = window.isCheckpointDue(nowMillis: now, forced: atBoundary);
    if (!due) {
      return ChunkWriteOutcome(
        index: index,
        state: ChunkWriteState.verifiedPending,
        leaseEpoch: leaseEpoch,
        checkpointSeq: checkpointSeq(taskId),
      );
    }

    final ChunkBatchCommit batch = commitPendingBatch(
      taskId: taskId,
      fileId: fileId,
      leaseEpoch: leaseEpoch,
      window: window,
      nowMillis: now,
    );
    return ChunkWriteOutcome(
      index: index,
      state: ChunkWriteState.committed,
      leaseEpoch: leaseEpoch,
      checkpointSeq: batch.checkpointSeq,
    );
  }

  /// Commits every receipt the window holds in one transaction, and clears the window.
  ///
  /// This is the **only** method that marks a chunk committed, so there is no path that
  /// records progress without a durable sync having been reported first.
  ///
  /// Each receipt is re-checked against the frozen manifest *inside* the transaction. §8
  /// requires a re-sent already-committed chunk to be verified rather than accepted because
  /// "已有块"; checking the receipt here means a caller cannot commit an index it never
  /// verified, and a content conflict fails the whole batch instead of committing part of
  /// it - a half-applied checkpoint would advance the sequence past work it did not record.
  ///
  /// The generation is re-checked inside the transaction because a resume may have advanced
  /// it while the bytes were being written.
  ///
  /// A window with nothing pending is a no-op: it returns the current sequence without
  /// opening a transaction, so an empty checkpoint cannot advance the sequence and make the
  /// sender's "does not regress" comparison meaningless.
  ChunkBatchCommit commitPendingBatch({
    required String taskId,
    required String fileId,
    required int leaseEpoch,
    required ChunkCommitWindow window,
    int? nowMillis,
  }) {
    if (!window.hasPending) {
      return ChunkBatchCommit(
        checkpointSeq: checkpointSeq(taskId),
        committedIndices: const <int>[],
      );
    }

    final int now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    final List<PendingChunkCommit> batch = window.pending;

    final ChunkBatchCommit result = database.transaction(() {
      _assertLease(taskId, leaseEpoch);

      final List<int> committed = <int>[];
      for (final PendingChunkCommit receipt in batch) {
        final StoredChunk frozen = readChunk(fileId, receipt.index);
        if (frozen.lengthBytes != receipt.lengthBytes ||
            frozen.sha256.toLowerCase() != receipt.sha256.toLowerCase()) {
          throw StorageException(
            StorageFailureCode.syncReceiptMismatch,
            'the verified receipt for $fileId[${receipt.index}] '
            '(${receipt.lengthBytes} bytes / ${receipt.sha256}) does not match the '
            'frozen manifest (${frozen.lengthBytes} bytes / ${frozen.sha256})',
          );
        }
        database.db.execute(
          "UPDATE chunks SET state = 'committed', committed_at = ? "
          'WHERE file_id = ? AND idx = ?;',
          <Object?>[now, fileId, receipt.index],
        );
        if (database.db.updatedRows == 0) {
          throw StorageException(
            StorageFailureCode.commitFailed,
            'chunk $fileId[${receipt.index}] disappeared before it could be committed',
          );
        }
        committed.add(receipt.index);
      }

      database.db.execute(
        'UPDATE tasks SET $checkpointSeqColumn = $checkpointSeqColumn + 1, '
        'updated_at = ? WHERE task_id = ?;',
        <Object?>[now, taskId],
      );
      if (database.db.updatedRows == 0) {
        throw StorageException(
          StorageFailureCode.staleLease,
          'task $taskId is not registered',
        );
      }

      return ChunkBatchCommit(
        checkpointSeq: checkpointSeq(taskId),
        committedIndices: List<int>.unmodifiable(committed),
      );
    });

    // Cleared only after the transaction committed. A failure above leaves the receipts in
    // place, and the bytes on disk, so the same batch is retried instead of the chunk rows
    // silently staying missing until a resume re-sends them.
    window.markFlushed();
    return result;
  }

  /// The task's last committed checkpoint sequence (§8).
  ///
  /// 0 means no checkpoint has been taken, which is what §8's counter starts at rather
  /// than a fabricated first sequence.
  int checkpointSeq(String taskId) {
    final ResultSet rows = database.db.select(
      'SELECT $checkpointSeqColumn FROM tasks WHERE task_id = ?;',
      <Object?>[taskId],
    );
    if (rows.isEmpty) {
      throw StorageException(
        StorageFailureCode.staleLease,
        'task $taskId is not registered',
      );
    }
    return rows.first[checkpointSeqColumn] as int;
  }

  /// Reads one chunk row.
  StoredChunk readChunk(String fileId, int index) {
    final ResultSet rows = database.db.select(
      'SELECT file_id, idx, offset_bytes, length_bytes, sha256, state FROM chunks '
      'WHERE file_id = ? AND idx = ?;',
      <Object?>[fileId, index],
    );
    if (rows.isEmpty) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'chunk $fileId[$index] is not registered',
      );
    }
    return _toRecord(rows.first);
  }

  /// Indices of chunks that are **not** committed, ascending.
  ///
  /// This is the recovery query. It reads chunk state only: there is no byte-counter
  /// input, because a counter cannot tell the difference between bytes that were written
  /// and bytes that were durably committed.
  List<int> missingChunkIndices(String fileId) {
    final ResultSet rows = database.db.select(
      "SELECT idx FROM chunks WHERE file_id = ? AND state = 'missing' ORDER BY idx;",
      <Object?>[fileId],
    );
    return <int>[for (final Row row in rows) row['idx'] as int];
  }

  /// Number of committed chunks for a file.
  int committedChunkCount(String fileId) {
    final ResultSet rows = database.db.select(
      "SELECT COUNT(*) AS c FROM chunks WHERE file_id = ? AND state = 'committed';",
      <Object?>[fileId],
    );
    return rows.first['c'] as int;
  }

  /// Whether every chunk of a file is committed.
  ///
  /// Note what this is *not*: it is not proof the file is correct. The whole-file digest
  /// is recomputed before export (T06-01); this only says nothing is left to transfer.
  bool isFullyCommitted(String fileId) {
    final ResultSet rows = database.db.select(
      'SELECT chunk_count FROM files WHERE file_id = ?;',
      <Object?>[fileId],
    );
    if (rows.isEmpty) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'file $fileId is not registered',
      );
    }
    return committedChunkCount(fileId) == rows.first['chunk_count'] as int;
  }

  /// Returns chunks to `missing`, used when verification finds them damaged.
  ///
  /// A damaged committed chunk is worse than a missing one, because recovery would trust
  /// it. §5 of the protocol allows `committedBytes` to fall for exactly this reason.
  void markChunksMissing(String fileId, Iterable<int> indices) {
    final List<int> targets = indices.toList();
    if (targets.isEmpty) {
      return;
    }
    database.transaction(() {
      final PreparedStatement update = database.db.prepare(
        "UPDATE chunks SET state = 'missing', committed_at = NULL "
        'WHERE file_id = ? AND idx = ?;',
      );
      try {
        for (final int index in targets) {
          update.execute(<Object?>[fileId, index]);
        }
      } finally {
        update.close();
      }
    });
  }

  void _assertLease(String taskId, int leaseEpoch) {
    final int current = this.leaseEpoch(taskId);
    if (leaseEpoch != current) {
      throw StorageException(
        StorageFailureCode.staleLease,
        'write generation $leaseEpoch is not current ($current) for task $taskId',
      );
    }
    if (current == 0) {
      throw StorageException(
        StorageFailureCode.staleLease,
        'no write generation has been allocated for task $taskId',
      );
    }
  }

  static StoredChunk _toRecord(Row row) => StoredChunk(
    fileId: row['file_id'] as String,
    index: row['idx'] as int,
    offsetBytes: row['offset_bytes'] as int,
    lengthBytes: row['length_bytes'] as int,
    sha256: row['sha256'] as String,
    state: ChunkState.fromColumn(row['state'] as String),
  );
}
