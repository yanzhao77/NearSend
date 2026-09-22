/// The sender's **mirror** of a client receiver's reported progress, §9.
///
/// §9 is precise about what this is:
///
/// > server 接收者：`/resume` 驱动本地接收恢复……client 接收者：先在本地持久化新 epoch、复核断点，
/// > 再提交 `receiverState={leaseEpoch,checkpointSeq,committedBytes}`；发送者验证**不回退**并更新镜像。
/// > **恢复只以接收端已经持久化的 committed 块与 checkpoint 为准**；发送端记录始终是镜像，
/// > **不得反向覆盖接收端本地事实**。
///
/// `AGENTS.md` §2 rule 8 says the same thing from the other side: "发送端记录只能作为镜像，不能覆盖
/// 接收端事实".
///
/// ## Why it is a separate class and not columns on `tasks`
///
/// Because the failure this guards against is somebody reading it as truth. A sender that
/// decided what to send from its mirror would send the wrong blocks the moment the previous
/// response was lost, and the mirror is *expected* to be stale - it only moves when the
/// receiver reports. Giving it its own table, its own type and a name that says whose numbers
/// these are makes that mistake require a deliberate lookup rather than an accidental one.
///
/// Nothing in this file is consulted by any decision about bytes.
library;

import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_schema.dart';

/// The receiver's last reported position, as the sender remembers it.
class ReceiverMirror {
  const ReceiverMirror({
    required this.transferId,
    required this.leaseEpoch,
    required this.checkpointSeq,
    required this.committedBytes,
    required this.updatedAtMillis,
  });

  final String transferId;
  final int leaseEpoch;
  final int checkpointSeq;
  final int committedBytes;
  final int updatedAtMillis;

  @override
  String toString() =>
      'ReceiverMirror($transferId, epoch $leaseEpoch, seq $checkpointSeq, '
      '$committedBytes B)';
}

/// What writing a receiver report did.
enum MirrorUpdateKind {
  /// The report moved the mirror forward and was recorded.
  advanced,

  /// The report was identical to the stored one, so nothing changed.
  unchanged,

  /// The report was behind the stored one. Recorded as a fact but **not** as progress.
  regressed,
}

/// Stores and reads the sender's mirror of a receiver's position.
class ReceiverMirrorRepository {
  ReceiverMirrorRepository(this.database, {this.now = _systemNow});

  final NearSendDatabase database;
  final int Function() now;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  /// The stored mirror, or null when nothing has been reported.
  ReceiverMirror? read(String transferId) {
    final ResultSet rows = database.db.select(
      'SELECT lease_epoch, checkpoint_seq, committed_bytes, updated_at FROM '
      '${StorageSchema.taskReceiverMirrorTable} WHERE transfer_id = ?;',
      <Object?>[transferId],
    );
    if (rows.isEmpty) {
      return null;
    }
    final Row row = rows.first;
    return ReceiverMirror(
      transferId: transferId,
      leaseEpoch: row['lease_epoch'] as int,
      checkpointSeq: row['checkpoint_seq'] as int,
      committedBytes: row['committed_bytes'] as int,
      updatedAtMillis: row['updated_at'] as int,
    );
  }

  /// Records a report, reporting honestly whether it moved forward.
  ///
  /// A regressing report is **recorded** rather than refused: §8 allows `committedBytes` to
  /// fall, because a whole-file verification can demote a damaged committed block back to
  /// `missing`. What must not happen is calling that progress, so the return value
  /// distinguishes the three cases instead of collapsing them into "accepted".
  MirrorUpdateKind record({
    required String transferId,
    required int leaseEpoch,
    required int checkpointSeq,
    required int committedBytes,
  }) {
    return database.transaction(() {
      final ReceiverMirror? existing = read(transferId);
      final int moment = now();

      if (existing == null) {
        _write(
          transferId: transferId,
          leaseEpoch: leaseEpoch,
          checkpointSeq: checkpointSeq,
          committedBytes: committedBytes,
          moment: moment,
        );
        return MirrorUpdateKind.advanced;
      }

      final bool identical =
          existing.leaseEpoch == leaseEpoch &&
          existing.checkpointSeq == checkpointSeq &&
          existing.committedBytes == committedBytes;
      if (identical) {
        return MirrorUpdateKind.unchanged;
      }

      final bool regressed =
          leaseEpoch < existing.leaseEpoch ||
          checkpointSeq < existing.checkpointSeq ||
          committedBytes < existing.committedBytes;

      _write(
        transferId: transferId,
        leaseEpoch: leaseEpoch,
        checkpointSeq: checkpointSeq,
        committedBytes: committedBytes,
        moment: moment,
      );
      return regressed ? MirrorUpdateKind.regressed : MirrorUpdateKind.advanced;
    });
  }

  /// Removes the mirror, for a cancel or a completed cleanup.
  void delete(String transferId) {
    database.transaction(() {
      database.db.execute(
        'DELETE FROM ${StorageSchema.taskReceiverMirrorTable} '
        'WHERE transfer_id = ?;',
        <Object?>[transferId],
      );
    });
  }

  void _write({
    required String transferId,
    required int leaseEpoch,
    required int checkpointSeq,
    required int committedBytes,
    required int moment,
  }) {
    database.db.execute(
      'INSERT INTO ${StorageSchema.taskReceiverMirrorTable} (transfer_id, lease_epoch, '
      'checkpoint_seq, committed_bytes, updated_at) VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(transfer_id) DO UPDATE SET lease_epoch = excluded.lease_epoch, '
      'checkpoint_seq = excluded.checkpoint_seq, '
      'committed_bytes = excluded.committed_bytes, updated_at = excluded.updated_at;',
      <Object?>[transferId, leaseEpoch, checkpointSeq, committedBytes, moment],
    );
  }
}
