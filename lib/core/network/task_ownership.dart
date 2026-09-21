/// Which paired peer a transfer belongs to, §7.
///
/// ## The gap this closes
///
/// §7 mixes two credential scopes in one table. Some rows ask for a "会话身份" - `offers`,
/// `authorization` - and others are "与已授权任务绑定" - `decision`, the chunk endpoints, the
/// control poll. T03-01's authoriser modelled the first and, having no way to relate a session
/// to a transfer, answered a session on a transfer-scoped route with `NOT_FOUND`. The ledger
/// recorded that honestly: "**会话到任务的映射未建模**……属**能力缺口而非安全缺口**（方向是「拒绝得
/// 太多」）".
///
/// A capability gap is still a gap, and for `server_to_client` it is a blocking one: the client
/// receiver has no task token before it decides, because §7 issues that token from `resume`,
/// which happens *after* the decision. So `POST /decision` would be unreachable by the only
/// caller entitled to make it.
///
/// ## Why the answer is a port rather than a lookup in the authoriser
///
/// The authoriser's job is to decide what §7 requires; which task belongs to which peer is a
/// storage fact. Keeping them apart means the fail-closed default - [NoTaskOwnership] - is a
/// named value a caller has to replace deliberately, and the existing authorisation tests keep
/// passing unchanged because "no mapping" is still the default.
///
/// The direction travels with the owner because §7's direction requirements are stated per
/// route, and a session grant carries no direction of its own. Returning them together means
/// the direction check stays in one place instead of being re-done by each endpoint.
library;

import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/protocol/transfer_direction.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_schema.dart';

/// The peer a transfer belongs to, and the direction it runs in.
class TaskOwner {
  const TaskOwner({required this.peerId, required this.direction});

  /// The paired peer, as the session identity names it. Never an address: §2 keeps identity
  /// and address apart, and an address is trivially spoofable on a LAN.
  final String peerId;

  final TransferDirection direction;

  @override
  String toString() => 'TaskOwner($peerId, ${direction.wireValue})';
}

/// Looks up which peer owns a transfer.
abstract class TaskOwnership {
  /// The owner of [transferId], or null when no peer owns it.
  ///
  /// Null is the fail-closed answer: it means a session identity may not reach the transfer,
  /// which is what §7's "任务查询对无权限资源统一 404" prescribes.
  TaskOwner? ownerOf(String transferId);
}

/// The default: nothing is owned by any peer.
///
/// Worth having as a named type rather than as a nullable field, for the same reason
/// `RejectingAuthenticator` exists: a server that has not wired the mapping must refuse, and
/// "no mapping" must not be indistinguishable from "no check".
class NoTaskOwnership implements TaskOwnership {
  const NoTaskOwnership();

  @override
  TaskOwner? ownerOf(String transferId) => null;
}

/// Reads and writes the peer-to-transfer binding from `task_assignments`.
class SqliteTaskOwnership implements TaskOwnership {
  SqliteTaskOwnership(this.database);

  final NearSendDatabase database;

  @override
  TaskOwner? ownerOf(String transferId) {
    final ResultSet rows = database.db.select(
      'SELECT a.peer_id, t.direction FROM ${StorageSchema.taskAssignmentsTable} AS a '
      'JOIN tasks AS t ON t.task_id = a.transfer_id WHERE a.transfer_id = ?;',
      <Object?>[transferId],
    );
    if (rows.isEmpty) {
      return null;
    }
    final Row row = rows.first;
    final TransferDirection? direction = TransferDirection.fromWireValue(
      row['direction'] as String,
    );
    if (direction == null) {
      // A stored direction this build does not define means the row was not written by this
      // build; refusing is the honest answer rather than picking one of the two.
      return null;
    }
    return TaskOwner(peerId: row['peer_id'] as String, direction: direction);
  }

  /// Binds [transferId] to [peerId], leaving an existing binding alone.
  ///
  /// Idempotent, and deliberately not an upsert: re-binding a transfer to a second peer would
  /// silently move who may read its files, which is exactly the "身份变化需要重新确认" case §6
  /// says needs a new decision rather than a new row.
  void assign(String transferId, String peerId) {
    database.transaction(() {
      database.db.execute(
        'INSERT INTO ${StorageSchema.taskAssignmentsTable} (transfer_id, peer_id, '
        'assigned_at) VALUES (?, ?, ?) ON CONFLICT(transfer_id) DO NOTHING;',
        <Object?>[transferId, peerId, DateTime.now().millisecondsSinceEpoch],
      );
    });
  }

  /// The peer bound to [transferId], or null.
  String? assignedPeer(String transferId) {
    final ResultSet rows = database.db.select(
      'SELECT peer_id FROM ${StorageSchema.taskAssignmentsTable} '
      'WHERE transfer_id = ?;',
      <Object?>[transferId],
    );
    return rows.isEmpty ? null : rows.first['peer_id'] as String;
  }
}
