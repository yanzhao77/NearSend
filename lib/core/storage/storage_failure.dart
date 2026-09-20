/// Local storage failure codes, and how they map onto the protocol error model.
///
/// Not every storage condition is a wire error. A database whose schema is newer than
/// the running build never reaches the peer; it is a local refusal. Inventing an HTTP
/// status for it would pollute the protocol's error table, so storage failures carry
/// their own stable codes and map to a protocol code only where one genuinely applies
/// (`docs/architecture/SYSTEM_ARCHITECTURE.md` §11 still requires a stable code, a
/// scope, retryability and a safe user-message key).
library;

import 'package:nearsend/core/protocol/protocol_exception.dart';

/// Stable codes for local storage failures.
enum StorageFailureCode {
  /// The stored schema version is newer than this build understands.
  ///
  /// Refused rather than migrated downwards: a newer build may have written structures
  /// that this one would corrupt by ignoring.
  schemaTooNew('NS-STORAGE-001', 'storage.schemaTooNew'),

  /// A migration step failed; the database was left at its previous version.
  migrationFailed('NS-STORAGE-002', 'storage.migrationFailed'),

  /// The pre-migration consistency backup could not be written.
  backupFailed('NS-STORAGE-003', 'storage.backupFailed'),

  /// A durable-sync receipt did not match the chunk it claims to describe.
  syncReceiptMismatch('NS-STORAGE-004', 'storage.syncReceiptMismatch'),

  /// A chunk commit was refused because the write generation is not current.
  staleLease('NS-STORAGE-005', 'storage.staleLease'),

  /// A chunk commit failed; the block must not be reported as acknowledged.
  commitFailed('NS-STORAGE-006', 'storage.commitFailed'),

  /// The stored data does not match the frozen manifest.
  manifestMismatch('NS-STORAGE-007', 'storage.manifestMismatch');

  const StorageFailureCode(this.code, this.messageKey);

  /// Stable diagnostic code, safe to show in a diagnostics panel.
  ///
  /// Distinct from the protocol's wire codes so a log reader can tell a local refusal
  /// from a peer-reported error.
  final String code;

  /// Stable key for the safe, localised user message.
  final String messageKey;

  /// The protocol error this maps to when it can appear in a response, else null.
  ///
  /// `staleLease` maps to `STALE_LEASE`; `commitFailed` to `DB_COMMIT_FAILED`, which §11
  /// says must not acknowledge the commit and must leave the state recoverable. The rest
  /// are local-only and have no honest wire equivalent.
  ProtocolErrorCode? get protocolCode {
    switch (this) {
      case StorageFailureCode.staleLease:
        return ProtocolErrorCode.staleLease;
      case StorageFailureCode.commitFailed:
        return ProtocolErrorCode.dbCommitFailed;
      case StorageFailureCode.manifestMismatch:
        return ProtocolErrorCode.manifestMismatch;
      case StorageFailureCode.schemaTooNew:
      case StorageFailureCode.migrationFailed:
      case StorageFailureCode.backupFailed:
      case StorageFailureCode.syncReceiptMismatch:
        return null;
    }
  }

  /// Whether retrying the same operation could succeed.
  ///
  /// Only a failed commit is retryable: §11 keeps the state recoverable in that case.
  /// A schema refusal will not improve by retrying, and a receipt mismatch means the
  /// caller's ordering was wrong, which retrying would repeat.
  bool get retryable => this == StorageFailureCode.commitFailed;
}

/// Thrown when a storage operation cannot proceed.
class StorageException implements Exception {
  const StorageException(this.code, this.detail, {this.cause});

  final StorageFailureCode code;

  /// Non-sensitive diagnostic context. Never a credential, a token, a full local path
  /// or file content.
  final String detail;

  final Object? cause;

  /// Renders as a protocol error when the failure can reach the peer.
  ProtocolError toProtocolError({ErrorScope scope = ErrorScope.platform}) =>
      ProtocolError(
        code: code.protocolCode ?? ProtocolErrorCode.dbCommitFailed,
        scope: scope,
        diagnosticContext: <String, String>{'storageCode': code.code},
        cause: cause ?? this,
      );

  @override
  String toString() => '${code.code}: $detail';
}
