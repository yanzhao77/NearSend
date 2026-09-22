/// What a receiver approved, persisted with the approval, §6 and §7.
///
/// §6: "批准清单摘要、保存位置以及空间估算一起持久化；**路径或身份变化需要重新确认**". Two things
/// follow from that sentence and this file exists for both.
///
/// The first is that the three facts travel together. A row that remembered the digest but not
/// where the bytes were going could not answer "is this still the transfer I approved", and the
/// whole point of re-confirming on a change is to be able to notice one.
///
/// The second is that the **save location is an opaque reference**, never a local path. §7
/// requires an error body to carry no full local path and `AGENTS.md` §5 keeps user file
/// listings out of logs and diagnostics; a directory the user chose is exactly that. The
/// platform adapter that knows what the reference means lives above this layer.
///
/// ## The space estimate is stored as the explanation, not as a verdict
///
/// §8 is emphatic that "空间计划输出每个卷的解释性明细……不能只返回布尔值", and §16.1 that an
/// unverifiable volume must be shown as such rather than folded into a pass. So what is
/// persisted is the whole breakdown - every line, its byte count and its reason - which is what
/// lets a later screen explain the decision instead of restating it.
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/core/storage/storage_failure.dart';
import 'package:nearsend/core/storage/storage_schema.dart';

/// §7's `decision: accept|reject`, as stored.
enum TransferDecision {
  accepted('accepted'),
  rejected('rejected');

  const TransferDecision(this.column);

  /// The database value. Deliberately not the wire word `accept`/`reject`: §10 already keeps
  /// protocol state names and database state names separate through one codec, and reusing the
  /// wire spelling here would put a second spelling of "accepted" in the codebase.
  final String column;

  static TransferDecision fromColumn(String value) => switch (value) {
    'accepted' => TransferDecision.accepted,
    'rejected' => TransferDecision.rejected,
    _ => throw StorageException(
      StorageFailureCode.commitFailed,
      'unknown decision "$value" in the database',
    ),
  };
}

/// One volume's part of a stored space estimate.
class SpaceVolumeSnapshot {
  const SpaceVolumeSnapshot({
    required this.volumeRef,
    required this.requiredBytes,
    required this.verdict,
    required this.lines,
    this.freeBytes,
    this.shortfallBytes,
  });

  /// An opaque volume handle, never a full local path.
  final String volumeRef;

  final int requiredBytes;
  final SpaceVerdict verdict;
  final List<SpaceLineSnapshot> lines;
  final int? freeBytes;
  final int? shortfallBytes;

  Map<String, Object?> toJson() => <String, Object?>{
    'volume': volumeRef,
    'requiredBytes': requiredBytes.toString(),
    'freeBytes': freeBytes?.toString(),
    'shortfallBytes': shortfallBytes?.toString(),
    'verdict': verdict.name,
    'lines': <Map<String, Object?>>[
      for (final SpaceLineSnapshot line in lines) line.toJson(),
    ],
  };

  static SpaceVolumeSnapshot parse(Map<String, Object?> json) {
    final Object? verdict = json['verdict'];
    final SpaceVerdict? parsed = SpaceVerdict.values
        .where((SpaceVerdict v) => v.name == verdict)
        .firstOrNull;
    if (parsed == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the stored space estimate carries a verdict this build does not define',
      );
    }
    final Object? lines = json['lines'];
    if (lines is! List) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the stored space estimate must carry its lines',
      );
    }
    return SpaceVolumeSnapshot(
      volumeRef: _string(json, 'volume'),
      requiredBytes: _decimal(json, 'requiredBytes'),
      freeBytes: _optionalDecimal(json, 'freeBytes'),
      shortfallBytes: _optionalDecimal(json, 'shortfallBytes'),
      verdict: parsed,
      lines: <SpaceLineSnapshot>[
        for (final Object? entry in lines)
          SpaceLineSnapshot.parse((entry! as Map).cast<String, Object?>()),
      ],
    );
  }
}

/// One explained component of a stored space estimate.
class SpaceLineSnapshot {
  const SpaceLineSnapshot({
    required this.need,
    required this.bytes,
    required this.reason,
  });

  final SpaceNeed need;
  final int bytes;

  /// Why this many bytes. Contains file ids and opaque volume handles, never a local path.
  final String reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'need': need.name,
    'bytes': bytes.toString(),
    'reason': reason,
  };

  static SpaceLineSnapshot parse(Map<String, Object?> json) {
    final Object? need = json['need'];
    final SpaceNeed? parsed = SpaceNeed.values
        .where((SpaceNeed n) => n.name == need)
        .firstOrNull;
    if (parsed == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the stored space estimate names a requirement this build does not define',
      );
    }
    return SpaceLineSnapshot(
      need: parsed,
      bytes: _decimal(json, 'bytes'),
      reason: _string(json, 'reason'),
    );
  }
}

/// The whole space estimate the receiver was shown.
class SpaceEstimateSnapshot {
  const SpaceEstimateSnapshot({
    required this.verdict,
    required this.requiredBytes,
    required this.volumes,
  });

  /// The worst verdict across the volumes, which is what the receiver acted on.
  final SpaceVerdict verdict;

  final int requiredBytes;
  final List<SpaceVolumeSnapshot> volumes;

  /// Builds a snapshot from a planner result, keeping every explanation line.
  factory SpaceEstimateSnapshot.of(SpacePlan plan) {
    int required = 0;
    for (final VolumeSpacePlan volume in plan.volumes) {
      required += volume.requiredBytes;
    }
    return SpaceEstimateSnapshot(
      verdict: plan.verdict,
      requiredBytes: required,
      volumes: <SpaceVolumeSnapshot>[
        for (final VolumeSpacePlan volume in plan.volumes)
          SpaceVolumeSnapshot(
            volumeRef: volume.volume.value,
            requiredBytes: volume.requiredBytes,
            freeBytes: volume.availability.freeBytes,
            shortfallBytes: volume.shortfallBytes,
            verdict: volume.verdict,
            lines: <SpaceLineSnapshot>[
              for (final SpaceLine line in volume.lines)
                SpaceLineSnapshot(
                  need: line.need,
                  bytes: line.bytes,
                  reason: line.reason,
                ),
            ],
          ),
      ],
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'verdict': verdict.name,
    'requiredBytes': requiredBytes.toString(),
    'volumes': <Map<String, Object?>>[
      for (final SpaceVolumeSnapshot volume in volumes) volume.toJson(),
    ],
  };

  static SpaceEstimateSnapshot parse(Map<String, Object?> json) {
    final Object? verdict = json['verdict'];
    final SpaceVerdict? parsed = SpaceVerdict.values
        .where((SpaceVerdict v) => v.name == verdict)
        .firstOrNull;
    if (parsed == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the stored space estimate carries a verdict this build does not define',
      );
    }
    final Object? volumes = json['volumes'];
    if (volumes is! List) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the stored space estimate must carry its volumes',
      );
    }
    return SpaceEstimateSnapshot(
      verdict: parsed,
      requiredBytes: _decimal(json, 'requiredBytes'),
      volumes: <SpaceVolumeSnapshot>[
        for (final Object? entry in volumes)
          SpaceVolumeSnapshot.parse((entry! as Map).cast<String, Object?>()),
      ],
    );
  }
}

/// A stored approval or rejection.
class TaskAuthorizationRecord {
  const TaskAuthorizationRecord({
    required this.transferId,
    required this.manifestDigest,
    required this.decision,
    required this.decidedAtMillis,
    this.saveLocationRef,
    this.spaceEstimate,
    this.receiptAtMillis,
  });

  final String transferId;

  /// The digest the receiver approved, which §6 requires to be part of the approval.
  final String manifestDigest;

  final TransferDecision decision;
  final int decidedAtMillis;

  /// An opaque handle for where the bytes will be saved.
  final String? saveLocationRef;

  final SpaceEstimateSnapshot? spaceEstimate;
  final int? receiptAtMillis;

  bool get isAccepted => decision == TransferDecision.accepted;
  bool get hasReceipt => receiptAtMillis != null;

  @override
  String toString() =>
      'TaskAuthorizationRecord($transferId, ${decision.column}, '
      'digest=$manifestDigest)';
}

/// Reads and writes the receiver's approval for one task.
class TaskAuthorizationRepository {
  TaskAuthorizationRepository(this.database, {this.now = _systemNow});

  final NearSendDatabase database;
  final int Function() now;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  /// Reads the stored approval, or null when the task has not been decided.
  TaskAuthorizationRecord? read(String transferId) {
    final ResultSet rows = database.db.select(
      'SELECT manifest_digest, decision, save_location_ref, space_estimate_json, '
      'decided_at, receipt_at FROM ${StorageSchema.taskAuthorizationsTable} '
      'WHERE transfer_id = ?;',
      <Object?>[transferId],
    );
    if (rows.isEmpty) {
      return null;
    }
    final Row row = rows.first;
    final String? estimateJson = row['space_estimate_json'] as String?;
    return TaskAuthorizationRecord(
      transferId: transferId,
      manifestDigest: row['manifest_digest'] as String,
      decision: TransferDecision.fromColumn(row['decision'] as String),
      decidedAtMillis: row['decided_at'] as int,
      saveLocationRef: row['save_location_ref'] as String?,
      spaceEstimate: estimateJson == null
          ? null
          : SpaceEstimateSnapshot.parse(
              (jsonDecode(estimateJson) as Map).cast<String, Object?>(),
            ),
      receiptAtMillis: row['receipt_at'] as int?,
    );
  }

  /// Records the receiver's decision, or returns the stored one when it agrees.
  ///
  /// §6 wants the digest, the save location and the space estimate persisted together with the
  /// approval, so they are written in one statement inside one transaction.
  ///
  /// Idempotent in the direction that matters: repeating the *same* decision for the *same*
  /// digest returns the stored record without rewriting it, so a retry cannot move the
  /// decision timestamp or erase a receipt. A *different* digest for a task that already has a
  /// decision is refused rather than absorbed - §6's "路径或身份变化需要重新确认" is a
  /// re-decision the receiver has to make, not something the server may assume.
  TaskAuthorizationRecord recordDecision({
    required String transferId,
    required String manifestDigest,
    required TransferDecision decision,
    String? saveLocationRef,
    SpaceEstimateSnapshot? spaceEstimate,
  }) {
    return database.transaction(() {
      final TaskAuthorizationRecord? existing = read(transferId);
      if (existing != null) {
        if (existing.manifestDigest == manifestDigest &&
            existing.decision == decision) {
          return existing;
        }
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidState,
          'this transfer already carries a decision for a different manifest digest or a '
          'different outcome; a change of terms requires the receiver to decide again',
        );
      }

      final int moment = now();
      database.db.execute(
        'INSERT INTO ${StorageSchema.taskAuthorizationsTable} (transfer_id, '
        'manifest_digest, decision, save_location_ref, space_estimate_json, decided_at, '
        'receipt_at) VALUES (?, ?, ?, ?, ?, ?, NULL);',
        <Object?>[
          transferId,
          manifestDigest,
          decision.column,
          saveLocationRef,
          spaceEstimate == null ? null : jsonEncode(spaceEstimate.toJson()),
          moment,
        ],
      );
      return read(transferId)!;
    });
  }

  /// Records that the client confirmed it stored the delivered credentials.
  void recordReceipt(String transferId) {
    database.transaction(() {
      final TaskAuthorizationRecord? existing = read(transferId);
      if (existing == null) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidState,
          'no decision has been recorded for this transfer, so there is no receipt to record',
        );
      }
      if (existing.hasReceipt) {
        return;
      }
      database.db.execute(
        'UPDATE ${StorageSchema.taskAuthorizationsTable} SET receipt_at = ? '
        'WHERE transfer_id = ?;',
        <Object?>[now(), transferId],
      );
    });
  }

  /// Removes the approval, for a cancel.
  void delete(String transferId) {
    database.transaction(() {
      database.db.execute(
        'DELETE FROM ${StorageSchema.taskAuthorizationsTable} WHERE transfer_id = ?;',
        <Object?>[transferId],
      );
    });
  }
}

String _string(Map<String, Object?> json, String field) {
  final Object? value = requireField(json, field, 'the stored space estimate');
  if (value is! String) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      'the stored space estimate field "$field" must be a string',
    );
  }
  return value;
}

int _decimal(Map<String, Object?> json, String field) => parseDecimalString(
  requireField(json, field, 'the stored space estimate'),
  field,
);

int? _optionalDecimal(Map<String, Object?> json, String field) {
  final Object? value = json[field];
  if (value == null) {
    return null;
  }
  return parseDecimalString(value, field);
}
