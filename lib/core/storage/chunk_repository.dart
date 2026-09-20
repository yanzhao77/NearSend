/// The chunk repository: the receiver's authority on resumable progress.
///
/// `AGENTS.md` §2 rules 5 to 7 and protocol §8 define what this class must guarantee:
///
/// * a **committed** chunk in SQLite is the only evidence of progress. Nothing here
///   exposes a byte counter, because a byte counter is exactly what a recovery path must
///   not trust.
/// * the order is `write → chunk digest → durable sync → commit → acknowledge`. The only
///   method that commits a chunk performs the whole sequence, so there is no API that
///   lets a caller commit first and sync later.
/// * a failure at any step must not acknowledge the chunk, so a failed commit leaves the
///   row `missing` and the chunk is re-sent rather than trusted.
/// * a commit is refused unless it presents the task's current write generation, and the
///   generation is re-checked inside the same transaction that commits the chunk - §8
///   warns that checking only at the request entry point lets an in-flight write land
///   after a resume has taken over.
library;

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_failure.dart';

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

  /// Writes, verifies, durably syncs and commits one chunk.
  ///
  /// This is the only method that can mark a chunk committed, and it cannot be completed
  /// without a sink that reports a successful durable sync. The reported length and
  /// digest are checked against the frozen manifest before the commit, so a sink that
  /// writes the wrong bytes fails the operation rather than recording false progress.
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
    final StoredChunk expected = readChunk(fileId, index);

    _assertLease(taskId, leaseEpoch);

    if (bytes.length != expected.lengthBytes) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'chunk $fileId[$index] received ${bytes.length} bytes but the frozen manifest '
        'requires ${expected.lengthBytes}',
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

    final int now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    return database.transaction(() {
      // Re-check inside the transaction: a resume may have advanced the generation while
      // the bytes were being written.
      _assertLease(taskId, leaseEpoch);

      database.db.execute(
        "UPDATE chunks SET state = 'committed', committed_at = ? "
        'WHERE file_id = ? AND idx = ?;',
        <Object?>[now, fileId, index],
      );
      if (database.db.updatedRows == 0) {
        throw StorageException(
          StorageFailureCode.commitFailed,
          'chunk $fileId[$index] disappeared before it could be committed',
        );
      }
      return readChunk(fileId, index);
    });
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
