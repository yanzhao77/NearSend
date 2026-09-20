/// Task and file state persistence, plus export records.
///
/// Two rules from the protocol and the architecture are enforced here rather than left
/// to callers, because both are easy to get wrong and expensive to get wrong:
///
/// 1. **Every state change goes through T02-02's state machines.** `transitionTask` and
///    `transitionFile` call `assertTransition`, so an undefined edge is refused with
///    `INVALID_STATE` instead of being written. §10 requires every transition to be
///    triggered by a defined event, and two peers that disagree about the edges will
///    disagree about whether a task is resumable.
/// 2. **An export can only be recorded for a fully committed file, and never twice to
///    different places.** §10 forbids blindly producing a second copy when an export's
///    result is unknown. The check counts committed chunks inside the same transaction
///    that writes the export record, so a file cannot be marked exported while a chunk
///    is still missing.
library;

import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/file_verification.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_failure.dart';
import 'package:nearsend/core/storage/storage_schema.dart';

/// A recorded export of one file.
class ExportRecord {
  const ExportRecord({
    required this.fileId,
    required this.targetUri,
    required this.result,
    required this.recordedAtMillis,
    this.savedPath,
  });

  final String fileId;

  /// Opaque reference to the destination the platform adapter produced.
  final String targetUri;

  /// `saved` once the copy is committed at the target, otherwise a failure marker.
  final String result;

  final int recordedAtMillis;

  /// The name the copy was written under, relative to [targetUri].
  ///
  /// Null only for rows written before schema version 2. Those records are kept as they
  /// are rather than backfilled with the frozen path, because that build genuinely did
  /// not record which name it used and the copy may have been renamed.
  final String? savedPath;

  bool get isSaved => result == savedResult;

  /// The value that means the user's file exists at [targetUri].
  static const String savedResult = 'saved';

  /// The value used when an export was attempted and failed.
  static const String failedResult = 'failed';

  @override
  String toString() =>
      'ExportRecord($fileId, $result, $recordedAtMillis'
      '${savedPath == null ? '' : ', $savedPath'})';
}

/// Reads and writes task state, file state and export records.
class TransferRepository {
  TransferRepository(this.database, {this.now = _systemNow});

  final NearSendDatabase database;

  /// Clock injection so tests do not depend on wall time.
  final int Function() now;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  /// The stored task state.
  TransferState taskState(String taskId) {
    final ResultSet rows = database.db.select(
      'SELECT state FROM tasks WHERE task_id = ?;',
      <Object?>[taskId],
    );
    if (rows.isEmpty) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'task $taskId is not registered',
      );
    }
    return _parseTransferState(rows.first['state'] as String, taskId);
  }

  /// Moves a task to [to], refusing an undefined transition.
  ///
  /// Returns the new state. The current state is read and written inside one
  /// transaction, so two concurrent transitions cannot both observe the same "from".
  TransferState transitionTask({
    required String taskId,
    required TransferState to,
  }) {
    return database.transaction(() {
      final TransferState from = taskState(taskId);
      TransferStateMachine.assertTransition(from, to);
      database.db.execute(
        'UPDATE tasks SET state = ?, updated_at = ? WHERE task_id = ?;',
        <Object?>[to.name, now(), taskId],
      );
      return to;
    });
  }

  /// The stored file state.
  FileState fileState(String fileId) {
    final ResultSet rows = database.db.select(
      'SELECT export_state FROM files WHERE file_id = ?;',
      <Object?>[fileId],
    );
    if (rows.isEmpty) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'file $fileId is not registered',
      );
    }
    return _parseFileState(rows.first['export_state'] as String, fileId);
  }

  /// Moves a file to [to], refusing an undefined transition.
  FileState transitionFile({required String fileId, required FileState to}) {
    return database.transaction(() {
      final FileState from = fileState(fileId);
      FileStateMachine.assertTransition(from, to);
      database.db.execute(
        'UPDATE files SET export_state = ? WHERE file_id = ?;',
        <Object?>[to.name, fileId],
      );
      return to;
    });
  }

  /// File ids of a task, in manifest order.
  List<String> fileIds(String taskId) {
    final ResultSet rows = database.db.select(
      'SELECT file_id FROM files WHERE task_id = ? ORDER BY rowid;',
      <Object?>[taskId],
    );
    return <String>[for (final Row row in rows) row['file_id'] as String];
  }

  /// The recorded export of a file, if any.
  ExportRecord? existingExport(String fileId) {
    final ResultSet rows = database.db.select(
      'SELECT target_uri, result, recorded_at, ${StorageSchema.exportsSavedPathColumn} '
      'FROM exports WHERE file_id = ?;',
      <Object?>[fileId],
    );
    if (rows.isEmpty) {
      return null;
    }
    final Row row = rows.first;
    return ExportRecord(
      fileId: fileId,
      targetUri: row['target_uri'] as String,
      result: row['result'] as String,
      recordedAtMillis: row['recorded_at'] as int,
      savedPath: row[StorageSchema.exportsSavedPathColumn] as String?,
    );
  }

  /// Records that a file was successfully written to [targetUri], and completes it.
  ///
  /// [verification] is required, not optional, so that "完成 = 终检通过且导出已提交" is a
  /// property of the code rather than of the caller's discipline. Recording an export is
  /// the moment the product tells the user their file is safe; the previous signature
  /// checked only that every chunk was committed, which is silent about whether those
  /// bytes are the right bytes.
  ///
  /// Refuses when:
  ///
  /// * [verification] is for a different file, or was not taken over this file's current
  ///   size - a receipt for something else proves nothing about this export;
  /// * [verification] is not exportable: a chunk is missing, a chunk failed its digest,
  ///   or the whole-file digest did not match;
  /// * not every chunk is committed - re-checked here rather than trusted from the
  ///   receipt, because the two components must not have to believe each other;
  /// * a **different** target already holds a saved copy - §10 forbids blindly producing
  ///   a second file when the previous result is unknown.
  ///
  /// Repeating the call with the same target and an exportable receipt is idempotent: the
  /// existing record is returned rather than a second one written.
  ExportRecord recordSavedExport({
    required String fileId,
    required String targetUri,
    required FileVerificationResult verification,
    required String savedPath,
  }) {
    return database.transaction(() {
      _assertVerifiedFor(fileId, verification);
      _assertFullyCommitted(fileId);

      final ExportRecord? existing = existingExport(fileId);
      if (existing != null && existing.isSaved) {
        if (existing.targetUri == targetUri) {
          return existing;
        }
        throw StorageException(
          StorageFailureCode.manifestMismatch,
          'file $fileId already has a saved export to a different target; refusing to '
          'record a second copy without the user confirming',
        );
      }

      final int moment = now();
      database.db.execute(
        'INSERT INTO exports (file_id, target_uri, result, recorded_at, '
        '${StorageSchema.exportsSavedPathColumn}) VALUES (?, ?, ?, ?, ?) '
        'ON CONFLICT(file_id) DO UPDATE SET target_uri = excluded.target_uri, '
        'result = excluded.result, recorded_at = excluded.recorded_at, '
        '${StorageSchema.exportsSavedPathColumn} = '
        'excluded.${StorageSchema.exportsSavedPathColumn};',
        <Object?>[
          fileId,
          targetUri,
          ExportRecord.savedResult,
          moment,
          savedPath,
        ],
      );

      // The file's own state follows in the same transaction, so a crash cannot leave an
      // export recorded against a file that is still "exporting".
      final FileState from = fileState(fileId);
      FileStateMachine.assertTransition(from, FileState.completed);
      database.db.execute(
        'UPDATE files SET export_state = ? WHERE file_id = ?;',
        <Object?>[FileState.completed.name, fileId],
      );

      return ExportRecord(
        fileId: fileId,
        targetUri: targetUri,
        result: ExportRecord.savedResult,
        recordedAtMillis: moment,
        savedPath: savedPath,
      );
    });
  }

  /// Requires the receipt to be about this file, as it is now.
  ///
  /// The size check is what stops a receipt from an earlier attempt being reused after
  /// the file was re-registered: a digest taken over four bytes says nothing about a file
  /// that is now eight.
  void _assertVerifiedFor(String fileId, FileVerificationResult verification) {
    if (verification.fileId != fileId) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'the verification receipt is for ${verification.fileId}, not $fileId',
      );
    }
    if (!verification.isExportable) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'file $fileId has not passed verification, so its export must not be recorded: '
        '${verification.summary}',
      );
    }
    final ResultSet rows = database.db.select(
      'SELECT size_bytes FROM files WHERE file_id = ?;',
      <Object?>[fileId],
    );
    if (rows.isEmpty) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'file $fileId is not registered',
      );
    }
    final int sizeBytes = rows.first['size_bytes'] as int;
    if (verification.expectedBytes != sizeBytes ||
        verification.verifiedBytes != sizeBytes) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'the verification receipt covers ${verification.verifiedBytes} of '
        '${verification.expectedBytes} B but file $fileId is $sizeBytes B',
      );
    }
  }

  /// Records a failed export attempt so the UI can offer a retry.
  ///
  /// A previous saved record is never overwritten: if the file was already saved, a later
  /// failure must not erase that fact, because the user's copy still exists.
  ExportRecord recordFailedExport({
    required String fileId,
    required String targetUri,
  }) {
    return database.transaction(() {
      final ExportRecord? existing = existingExport(fileId);
      if (existing != null && existing.isSaved) {
        return existing;
      }
      final int moment = now();
      database.db.execute(
        'INSERT INTO exports (file_id, target_uri, result, recorded_at) '
        'VALUES (?, ?, ?, ?) '
        'ON CONFLICT(file_id) DO UPDATE SET target_uri = excluded.target_uri, '
        'result = excluded.result, recorded_at = excluded.recorded_at;',
        <Object?>[fileId, targetUri, ExportRecord.failedResult, moment],
      );
      return ExportRecord(
        fileId: fileId,
        targetUri: targetUri,
        result: ExportRecord.failedResult,
        recordedAtMillis: moment,
      );
    });
  }

  void _assertFullyCommitted(String fileId) {
    final ResultSet files = database.db.select(
      'SELECT chunk_count FROM files WHERE file_id = ?;',
      <Object?>[fileId],
    );
    if (files.isEmpty) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'file $fileId is not registered',
      );
    }
    final int expected = files.first['chunk_count'] as int;
    final ResultSet committed = database.db.select(
      "SELECT COUNT(*) AS c FROM chunks WHERE file_id = ? AND state = 'committed';",
      <Object?>[fileId],
    );
    final int actual = committed.first['c'] as int;
    if (actual != expected) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'file $fileId has $actual of $expected chunks committed; an export must not be '
        'recorded before every chunk is committed',
      );
    }
  }

  static TransferState _parseTransferState(String value, String taskId) {
    for (final TransferState state in TransferState.values) {
      if (state.name == value) {
        return state;
      }
    }
    throw StorageException(
      StorageFailureCode.commitFailed,
      'task $taskId has unknown state "$value"',
    );
  }

  static FileState _parseFileState(String value, String fileId) {
    for (final FileState state in FileState.values) {
      if (state.name == value) {
        return state;
      }
    }
    throw StorageException(
      StorageFailureCode.commitFailed,
      'file $fileId has unknown state "$value"',
    );
  }
}
