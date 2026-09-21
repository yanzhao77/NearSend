/// The only translation boundary between protocol/domain states and SQLite text.
///
/// Wire names are `UPPER_SNAKE_CASE` and are owned by `TransferState.wireName`.
/// SQLite keeps the lower/camel-case values written by the original schema.  Those
/// representations deliberately do not leak into business code: renaming a Dart enum or
/// changing a wire spelling must not silently rewrite the on-disk contract.
library;

import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/storage_failure.dart';

/// Encodes and decodes the stable state values stored in SQLite.
abstract final class StorageStateCodec {
  static String encodeTransfer(TransferState state) => switch (state) {
    TransferState.preparing => 'preparing',
    TransferState.staging => 'staging',
    TransferState.waitingAccept => 'waitingAccept',
    TransferState.ready => 'ready',
    TransferState.transferring => 'transferring',
    TransferState.pausing => 'pausing',
    TransferState.paused => 'paused',
    TransferState.interrupted => 'interrupted',
    TransferState.checkingResume => 'checkingResume',
    TransferState.verifying => 'verifying',
    TransferState.exporting => 'exporting',
    TransferState.completed => 'completed',
    TransferState.partiallyCompleted => 'partiallyCompleted',
    TransferState.blocked => 'blocked',
    TransferState.failed => 'failed',
    TransferState.cancelled => 'cancelled',
  };

  static TransferState decodeTransfer(String value, {required String taskId}) {
    final TransferState? state = switch (value) {
      'preparing' => TransferState.preparing,
      'staging' => TransferState.staging,
      'waitingAccept' => TransferState.waitingAccept,
      'ready' => TransferState.ready,
      'transferring' => TransferState.transferring,
      'pausing' => TransferState.pausing,
      'paused' => TransferState.paused,
      'interrupted' => TransferState.interrupted,
      'checkingResume' => TransferState.checkingResume,
      'verifying' => TransferState.verifying,
      'exporting' => TransferState.exporting,
      'completed' => TransferState.completed,
      'partiallyCompleted' => TransferState.partiallyCompleted,
      'blocked' => TransferState.blocked,
      'failed' => TransferState.failed,
      'cancelled' => TransferState.cancelled,
      _ => null,
    };
    if (state != null) {
      return state;
    }
    throw StorageException(
      StorageFailureCode.commitFailed,
      'task $taskId has unknown state "$value"',
    );
  }

  static String encodeFile(FileState state) => switch (state) {
    FileState.pending => 'pending',
    FileState.preparing => 'preparing',
    FileState.transferring => 'transferring',
    FileState.verifying => 'verifying',
    FileState.exporting => 'exporting',
    FileState.completed => 'completed',
    FileState.failed => 'failed',
    FileState.skipped => 'skipped',
  };

  static FileState decodeFile(String value, {required String fileId}) {
    final FileState? state = switch (value) {
      'pending' => FileState.pending,
      'preparing' => FileState.preparing,
      'transferring' => FileState.transferring,
      'verifying' => FileState.verifying,
      'exporting' => FileState.exporting,
      'completed' => FileState.completed,
      'failed' => FileState.failed,
      'skipped' => FileState.skipped,
      _ => null,
    };
    if (state != null) {
      return state;
    }
    throw StorageException(
      StorageFailureCode.commitFailed,
      'file $fileId has unknown state "$value"',
    );
  }
}
