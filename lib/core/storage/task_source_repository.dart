/// Where a sending task reads its files from, §7's chunk `GET`.
///
/// §7 makes the `GET` "仅 server_to_client": the server is the sender, so when a client asks
/// for chunk *n* this process has to produce those bytes from a file the user chose. §8 lets a
/// transfer be resumed after a restart, so the location cannot live only in memory - a paused
/// transfer that resumes tomorrow must still know which file it was sending.
///
/// What is stored is an **opaque reference**, never a full local path: §7 requires an error body
/// to carry no full local path and `AGENTS.md` §5 keeps user file locations out of logs and
/// diagnostics. The platform adapter is what turns a reference back into something readable.
///
/// ## Why the size is stored next to it
///
/// §8 derives a chunk's expected length from the frozen manifest and checks the body against it.
/// Recording the size the source had when it was chosen lets a `GET` notice that the user's file
/// has changed underneath the task and answer `SOURCE_CHANGED` (422) rather than serving bytes
/// that no longer match the digest the receiver will verify against.
library;

import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_schema.dart';

/// One recorded source file.
class TaskSourceRecord {
  const TaskSourceRecord({
    required this.transferId,
    required this.fileId,
    required this.sourceRef,
    required this.sizeBytes,
  });

  final String transferId;
  final String fileId;

  /// An opaque platform handle. Never a full local path.
  final String sourceRef;

  /// The size the source had when the task was created.
  final int sizeBytes;

  @override
  String toString() => 'TaskSourceRecord($fileId, ${sizeBytes}B)';
}

/// Reads and writes where a sending task's files come from.
class TaskSourceRepository {
  TaskSourceRepository(this.database);

  final NearSendDatabase database;

  /// Records one file's source, leaving an existing row alone.
  ///
  /// Not an upsert on purpose: re-pointing a task at a different file would make the chunks
  /// already sent describe one file and the rest another, and the digest the receiver holds
  /// would be a statement about neither.
  void record({
    required String transferId,
    required String fileId,
    required String sourceRef,
    required int sizeBytes,
  }) {
    database.transaction(() {
      database.db.execute(
        'INSERT INTO ${StorageSchema.taskSourcesTable} (transfer_id, file_id, '
        'source_ref, size_bytes) VALUES (?, ?, ?, ?) '
        'ON CONFLICT(transfer_id, file_id) DO NOTHING;',
        <Object?>[transferId, fileId, sourceRef, sizeBytes],
      );
    });
  }

  /// The recorded source for one file, or null when there is none.
  TaskSourceRecord? read(String transferId, String fileId) {
    final ResultSet rows = database.db.select(
      'SELECT source_ref, size_bytes FROM ${StorageSchema.taskSourcesTable} '
      'WHERE transfer_id = ? AND file_id = ?;',
      <Object?>[transferId, fileId],
    );
    if (rows.isEmpty) {
      return null;
    }
    return TaskSourceRecord(
      transferId: transferId,
      fileId: fileId,
      sourceRef: rows.first['source_ref'] as String,
      sizeBytes: rows.first['size_bytes'] as int,
    );
  }

  /// Every recorded source of a task, in the order they were recorded.
  List<TaskSourceRecord> readAll(String transferId) {
    final ResultSet rows = database.db.select(
      'SELECT file_id, source_ref, size_bytes FROM ${StorageSchema.taskSourcesTable} '
      'WHERE transfer_id = ? ORDER BY rowid;',
      <Object?>[transferId],
    );
    return <TaskSourceRecord>[
      for (final Row row in rows)
        TaskSourceRecord(
          transferId: transferId,
          fileId: row['file_id'] as String,
          sourceRef: row['source_ref'] as String,
          sizeBytes: row['size_bytes'] as int,
        ),
    ];
  }
}
