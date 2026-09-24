import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/protocol/relative_path.dart';
import 'package:nearsend/core/storage/export_naming.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_schema.dart';

enum ReceiveOutputState { planned, exporting, saved, failed }

class ReceiveOutputChoice {
  const ReceiveOutputChoice({
    required this.fileId,
    required this.originalPath,
    required this.selectedName,
  });

  final String fileId;
  final String originalPath;
  final String selectedName;
}

class ReceiveOutputPlan {
  const ReceiveOutputPlan({
    required this.transferId,
    required this.fileId,
    required this.originalPath,
    required this.selectedName,
    required this.targetRef,
    required this.conflictPolicy,
    required this.state,
    required this.updatedAtMillis,
    this.finalName,
    this.finalTargetRef,
  });

  final String transferId;
  final String fileId;
  final String originalPath;
  final String selectedName;
  final String targetRef;
  final NameConflictPolicy conflictPolicy;
  final ReceiveOutputState state;
  final String? finalName;
  final String? finalTargetRef;
  final int updatedAtMillis;
}

/// Persists local output mapping without changing the peer's frozen manifest.
class ReceiveOutputPlanRepository {
  ReceiveOutputPlanRepository(this.database, {int Function()? now})
    : now = now ?? _systemNow;

  final NearSendDatabase database;
  final int Function() now;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  List<ReceiveOutputPlan> create({
    required String transferId,
    required List<ReceiveOutputChoice> choices,
    required String targetRef,
    NameConflictPolicy conflictPolicy = NameConflictPolicy.autoRename,
  }) {
    uuidToBytes(transferId, 'transferId');
    if (choices.isEmpty) {
      throw ArgumentError.value(choices, 'choices', 'must not be empty');
    }
    if (targetRef.trim().isEmpty) {
      throw ArgumentError.value(targetRef, 'targetRef', 'must not be empty');
    }
    final Set<String> fileIds = <String>{};
    for (final ReceiveOutputChoice choice in choices) {
      uuidToBytes(choice.fileId, 'fileId');
      if (!fileIds.add(choice.fileId)) {
        throw ArgumentError.value(
          choice.fileId,
          'choices',
          'contains a duplicate fileId',
        );
      }
      RelativePathRules.validate(choice.originalPath);
      _validateSelectedName(choice.selectedName);
    }

    database.transaction(() {
      for (final ReceiveOutputChoice choice in choices) {
        final ReceiveOutputPlan? existing = read(transferId, choice.fileId);
        if (existing != null) {
          if (existing.originalPath != choice.originalPath ||
              existing.selectedName != choice.selectedName ||
              existing.targetRef != targetRef ||
              existing.conflictPolicy != conflictPolicy) {
            throw const ProtocolViolation(
              ProtocolErrorCode.invalidState,
              'a different output plan already exists for this file',
            );
          }
          continue;
        }
        database.db.execute(
          'INSERT INTO ${StorageSchema.receiveOutputPlansTable} '
          '(transfer_id, file_id, original_path, selected_name, target_ref, '
          'conflict_policy, output_state, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?);',
          <Object?>[
            transferId,
            choice.fileId,
            choice.originalPath,
            choice.selectedName,
            targetRef,
            conflictPolicy.name,
            ReceiveOutputState.planned.name,
            now(),
          ],
        );
      }
    });
    return readTransfer(transferId);
  }

  ReceiveOutputPlan? read(String transferId, String fileId) {
    final ResultSet rows = database.db.select(
      'SELECT * FROM ${StorageSchema.receiveOutputPlansTable} '
      'WHERE transfer_id = ? AND file_id = ?;',
      <Object?>[transferId, fileId],
    );
    return rows.isEmpty ? null : _decode(rows.single);
  }

  List<ReceiveOutputPlan> readTransfer(String transferId) =>
      <ReceiveOutputPlan>[
        for (final Row row in database.db.select(
          'SELECT * FROM ${StorageSchema.receiveOutputPlansTable} '
          'WHERE transfer_id = ? ORDER BY rowid;',
          <Object?>[transferId],
        ))
          _decode(row),
      ];

  void markExporting(String transferId, String fileId) {
    _transition(
      transferId,
      fileId,
      from: const <ReceiveOutputState>{
        ReceiveOutputState.planned,
        ReceiveOutputState.failed,
      },
      to: ReceiveOutputState.exporting,
    );
  }

  void markSaved({
    required String transferId,
    required String fileId,
    required String finalName,
    String? finalTargetRef,
  }) {
    database.transaction(() {
      final ReceiveOutputPlan plan = _required(transferId, fileId);
      if (plan.state == ReceiveOutputState.saved &&
          plan.finalName == finalName &&
          plan.finalTargetRef == finalTargetRef) {
        return;
      }
      if (plan.state != ReceiveOutputState.exporting) {
        throw StateError('only an exporting output plan can become saved');
      }
      database.db.execute(
        'UPDATE ${StorageSchema.receiveOutputPlansTable} SET output_state = ?, '
        'final_name = ?, final_target_ref = ?, updated_at = ? '
        'WHERE transfer_id = ? AND file_id = ?;',
        <Object?>[
          ReceiveOutputState.saved.name,
          finalName,
          finalTargetRef,
          now(),
          transferId,
          fileId,
        ],
      );
    });
  }

  void markFailed(String transferId, String fileId) {
    _transition(
      transferId,
      fileId,
      from: const <ReceiveOutputState>{ReceiveOutputState.exporting},
      to: ReceiveOutputState.failed,
    );
  }

  void _transition(
    String transferId,
    String fileId, {
    required Set<ReceiveOutputState> from,
    required ReceiveOutputState to,
  }) {
    database.transaction(() {
      final ReceiveOutputPlan plan = _required(transferId, fileId);
      if (plan.state == to) return;
      if (!from.contains(plan.state)) {
        throw StateError(
          'output plan cannot transition from ${plan.state.name} to ${to.name}',
        );
      }
      database.db.execute(
        'UPDATE ${StorageSchema.receiveOutputPlansTable} '
        'SET output_state = ?, updated_at = ? WHERE transfer_id = ? AND file_id = ?;',
        <Object?>[to.name, now(), transferId, fileId],
      );
    });
  }

  ReceiveOutputPlan _required(String transferId, String fileId) {
    final ReceiveOutputPlan? plan = read(transferId, fileId);
    if (plan == null) throw StateError('no output plan exists for this file');
    return plan;
  }

  static void _validateSelectedName(String value) {
    RelativePathRules.validate(value);
    if (value.contains('/')) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidPath,
        'a selected output name must be one file name, not a relative path',
      );
    }
  }

  static ReceiveOutputPlan _decode(Row row) => ReceiveOutputPlan(
    transferId: row['transfer_id'] as String,
    fileId: row['file_id'] as String,
    originalPath: row['original_path'] as String,
    selectedName: row['selected_name'] as String,
    targetRef: row['target_ref'] as String,
    conflictPolicy: NameConflictPolicy.values.byName(
      row['conflict_policy'] as String,
    ),
    state: ReceiveOutputState.values.byName(row['output_state'] as String),
    finalName: row['final_name'] as String?,
    finalTargetRef: row['final_target_ref'] as String?,
    updatedAtMillis: row['updated_at'] as int,
  );
}
