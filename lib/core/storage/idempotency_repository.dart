/// Durable `request_id` idempotency, protocol §9 and §10.
///
/// The in-memory rules live in `protocol/idempotency.dart` (T02-02) and are the single
/// authority for *what* idempotency means. This file is the storage half: it makes the
/// record durable and, more importantly, commits the record **in the same transaction as
/// the effect it describes**.
///
/// ## Why the same transaction matters
///
/// A record written in one transaction and an effect applied in another can diverge in
/// both directions, and both are harmful:
///
/// * effect committed, record lost - a retry repeats the effect, so a chunk is written
///   twice or a stage machine advances twice;
/// * record committed, effect lost - a retry replays a result that never happened, and
///   the peer is told an operation succeeded when it did not.
///
/// [executeAtomically] therefore runs the effect and writes the record inside one
/// transaction: a failure rolls back both, and a retry re-runs the effect, which is
/// correct because nothing was committed.
///
/// ## Concurrency without an in-flight window
///
/// A duplicate arriving while the first is still running blocks on the write lock taken
/// by `BEGIN IMMEDIATE`, then finds the record already `completed` and replays it. So for
/// an atomic operation there is no observable 202 window, and none is needed. The
/// two-phase [beginInFlight]/[complete] pair exists only for genuinely long operations
/// such as recovery, where §9 explicitly wants a 202 answer.
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/protocol/idempotency.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_failure.dart';

/// What happened when a durable request id was presented.
enum IdempotencyExecutionKind {
  /// Not seen before: the effect ran and its result was recorded.
  executed,

  /// Already completed with identical parameters: the stored result is returned and the
  /// effect was **not** run again.
  replayed,

  /// The same id arrived with different parameters.
  conflict,

  /// A long operation is still in progress; answer 202.
  inFlight,
}

/// The outcome of presenting a durable request id.
class IdempotencyExecution {
  const IdempotencyExecution(this.kind, {this.result, this.leaseEpoch});

  final IdempotencyExecutionKind kind;

  /// The stored or freshly produced result. Present for [executed] and [replayed].
  final Map<String, Object?>? result;

  /// The write generation recorded with the result.
  final int? leaseEpoch;

  bool get succeeded =>
      kind == IdempotencyExecutionKind.executed ||
      kind == IdempotencyExecutionKind.replayed;

  @override
  String toString() => 'IdempotencyExecution(${kind.name})';
}

/// A persisted idempotency record.
class PersistedIdempotencyRecord {
  const PersistedIdempotencyRecord({
    required this.requestId,
    required this.requestDigest,
    required this.state,
    required this.leaseEpoch,
    this.result,
    this.expiresAtMillis,
  });

  final String requestId;
  final String requestDigest;
  final IdempotencyState state;
  final int leaseEpoch;
  final Map<String, Object?>? result;
  final int? expiresAtMillis;
}

/// Stores and replays request ids.
class IdempotencyRepository {
  IdempotencyRepository(this.database, {this.now = _systemNow});

  final NearSendDatabase database;

  /// Clock injection so expiry tests do not depend on wall time.
  final int Function() now;

  /// How long a completed record is kept.
  ///
  /// §10 keeps completion credentials for seven days. The same period is used here so a
  /// retry that arrives within the retention window still replays rather than re-running
  /// the effect.
  static const Duration defaultRetention = Duration(days: 7);

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  /// Runs [effect] and records its result under [requestId] in one transaction.
  ///
  /// The effect must be safe to run inside a transaction and must not open one itself.
  /// If it throws, nothing is committed: no record and no effect.
  IdempotencyExecution executeAtomically({
    required RequestScope scope,
    required String requestId,
    required String requestDigest,
    required int leaseEpoch,
    required Map<String, Object?> Function() effect,
    Duration retention = defaultRetention,
  }) {
    _validateRequestId(requestId);

    return database.transaction(() {
      final PersistedIdempotencyRecord? existing = _read(scope, requestId);
      if (existing != null) {
        return _replayOrRefuse(existing, requestDigest);
      }

      final int moment = now();
      _insertInFlight(
        scope: scope,
        requestId: requestId,
        requestDigest: requestDigest,
        leaseEpoch: leaseEpoch,
        nowMillis: moment,
      );

      // Runs inside the same transaction. An exception here rolls back the in-flight row
      // as well, so a retry starts clean rather than finding a phantom record.
      final Map<String, Object?> result = effect();

      _markCompleted(
        scope: scope,
        requestId: requestId,
        result: result,
        nowMillis: moment,
        expiresAtMillis: moment + retention.inMilliseconds,
      );

      return IdempotencyExecution(
        IdempotencyExecutionKind.executed,
        result: result,
        leaseEpoch: leaseEpoch,
      );
    });
  }

  /// Records an in-flight long operation, for callers that must answer 202.
  ///
  /// Prefer [executeAtomically]. Use this only when the work genuinely outlives the
  /// request, which is why it is a separate, explicitly named method.
  IdempotencyExecution beginInFlight({
    required RequestScope scope,
    required String requestId,
    required String requestDigest,
    required int leaseEpoch,
  }) {
    _validateRequestId(requestId);
    return database.transaction(() {
      final PersistedIdempotencyRecord? existing = _read(scope, requestId);
      if (existing != null) {
        return _replayOrRefuse(existing, requestDigest);
      }
      _insertInFlight(
        scope: scope,
        requestId: requestId,
        requestDigest: requestDigest,
        leaseEpoch: leaseEpoch,
        nowMillis: now(),
      );
      return IdempotencyExecution(
        IdempotencyExecutionKind.executed,
        leaseEpoch: leaseEpoch,
      );
    });
  }

  /// Records the result of an in-flight operation.
  void complete({
    required RequestScope scope,
    required String requestId,
    required Map<String, Object?> result,
    Duration retention = defaultRetention,
  }) {
    final int moment = now();
    database.transaction(() {
      _markCompleted(
        scope: scope,
        requestId: requestId,
        result: result,
        nowMillis: moment,
        expiresAtMillis: moment + retention.inMilliseconds,
      );
    });
  }

  /// Looks up a record without changing anything.
  PersistedIdempotencyRecord? lookup(RequestScope scope, String requestId) =>
      _read(scope, requestId);

  /// Deletes completed records whose retention has passed.
  ///
  /// §10 gives completed credentials a seven-day life and says active tasks are not
  /// removed by retention, so only completed rows are eligible. In-flight rows are left
  /// alone: deleting one would let its effect be applied twice.
  int purgeExpired() {
    final int moment = now();
    return database.transaction(() {
      database.db.execute(
        "DELETE FROM idempotency WHERE state = 'completed' "
        'AND expires_at IS NOT NULL AND expires_at <= ?;',
        <Object?>[moment],
      );
      return database.db.updatedRows;
    });
  }

  IdempotencyExecution _replayOrRefuse(
    PersistedIdempotencyRecord existing,
    String requestDigest,
  ) {
    if (existing.requestDigest != requestDigest) {
      return IdempotencyExecution(
        IdempotencyExecutionKind.conflict,
        leaseEpoch: existing.leaseEpoch,
      );
    }
    if (existing.state == IdempotencyState.inFlight) {
      return IdempotencyExecution(
        IdempotencyExecutionKind.inFlight,
        leaseEpoch: existing.leaseEpoch,
      );
    }
    return IdempotencyExecution(
      IdempotencyExecutionKind.replayed,
      result: existing.result,
      leaseEpoch: existing.leaseEpoch,
    );
  }

  PersistedIdempotencyRecord? _read(RequestScope scope, String requestId) {
    final ResultSet rows = database.db.select(
      'SELECT request_digest, state, lease_epoch, result_json, expires_at '
      'FROM idempotency WHERE transfer_id = ? AND operation = ? '
      'AND credential_fingerprint = ? AND request_id = ?;',
      <Object?>[
        scope.transferId,
        scope.operation.name,
        scope.credentialFingerprint,
        requestId,
      ],
    );
    if (rows.isEmpty) {
      return null;
    }
    final Row row = rows.first;
    final String? resultJson = row['result_json'] as String?;
    return PersistedIdempotencyRecord(
      requestId: requestId,
      requestDigest: row['request_digest'] as String,
      state: switch (row['state'] as String) {
        'in_flight' => IdempotencyState.inFlight,
        'completed' => IdempotencyState.completed,
        final String other => throw StorageException(
          StorageFailureCode.commitFailed,
          'unknown idempotency state "$other"',
        ),
      },
      leaseEpoch: row['lease_epoch'] as int,
      result: resultJson == null
          ? null
          : (jsonDecode(resultJson) as Map).cast<String, Object?>(),
      expiresAtMillis: row['expires_at'] as int?,
    );
  }

  void _insertInFlight({
    required RequestScope scope,
    required String requestId,
    required String requestDigest,
    required int leaseEpoch,
    required int nowMillis,
  }) {
    database.db.execute(
      'INSERT INTO idempotency (transfer_id, operation, credential_fingerprint, '
      'request_id, request_digest, state, lease_epoch, result_json, created_at, '
      "expires_at) VALUES (?, ?, ?, ?, ?, 'in_flight', ?, NULL, ?, NULL);",
      <Object?>[
        scope.transferId,
        scope.operation.name,
        scope.credentialFingerprint,
        requestId,
        requestDigest,
        leaseEpoch,
        nowMillis,
      ],
    );
  }

  void _markCompleted({
    required RequestScope scope,
    required String requestId,
    required Map<String, Object?> result,
    required int nowMillis,
    required int expiresAtMillis,
  }) {
    database.db.execute(
      "UPDATE idempotency SET state = 'completed', result_json = ?, expires_at = ? "
      'WHERE transfer_id = ? AND operation = ? AND credential_fingerprint = ? '
      'AND request_id = ?;',
      <Object?>[
        jsonEncode(result),
        expiresAtMillis,
        scope.transferId,
        scope.operation.name,
        scope.credentialFingerprint,
        requestId,
      ],
    );
    if (database.db.updatedRows == 0) {
      throw StorageException(
        StorageFailureCode.commitFailed,
        'idempotency record $requestId disappeared before it could be completed',
      );
    }
  }

  static void _validateRequestId(String requestId) {
    // §9: the request id is a canonical UUID. Reusing the shared validator keeps one
    // definition of "canonical" across the protocol and the storage layer.
    uuidToBytes(requestId, 'requestId');
  }
}
