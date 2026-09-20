/// Placing a verified file at the user's target, then freeing the app's copy.
///
/// `APP_AND_SERVICE_DESIGN.md` §7 fixes the order this file exists to enforce:
///
/// > 导出使用安全文件名策略、冲突策略和尽可能原子的目标提交；导出成功记录持久化后再清理暂存。
/// > 若清理失败只影响空间回收，不把已导出文件改为失败。
///
/// Two properties are worth more than the rest, and both are structural here rather than
/// checked at runtime:
///
/// 1. **The export record is written before staging is released.** If the record write
///    fails, staging survives, because the only durable evidence that the user has a file
///    is that record. Releasing first would leave a crash with no copy and no way to know.
/// 2. **The port cannot delete anything at the target.** [ExportSink] has no
///    delete-at-target method to call, so no path through this service can remove a file
///    the user already has. `AGENTS.md` §5 and V2.1 §16.1 both require that cancelling a
///    task must never delete an exported file, and V2.1 adds that deleting a saved file
///    must be a separate, explicit action. Leaving the capability out of the port is a
///    stronger guarantee than remembering not to call it.
///
/// ## Not claiming atomicity
///
/// V2.1 §15: "仅在同一可控文件系统且支持该操作时使用原子重命名……不能伪称原子操作". So
/// the sink reports whether it could commit atomically and the outcome carries that fact
/// rather than a claim. A document provider that cannot rename atomically is not a
/// failure; describing it as atomic would be a false assurance in a diagnostics panel.
///
/// ## The window the app cannot prove
///
/// V2.1 §15: "对无法证明导出提交结果的后端，重启后检查已有目标或请用户确认，不盲目新建重复文件".
/// Between the target commit and the export record there is a window in which the copy
/// exists but nothing local says so. This service closes it when it can: before writing,
/// it looks for an entry at the natural name whose **digest** matches, and reuses it
/// instead of writing a second copy. When the provider cannot report a digest that check
/// cannot be made, and the residual is registered in `docs/PROJECT_LEDGER.md` §5.
library;

import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/storage/export_naming.dart';
import 'package:nearsend/core/storage/file_verification.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_failure.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

/// One entry the target already holds.
class TargetEntry {
  const TargetEntry({required this.path, this.sizeBytes, this.sha256});

  /// Path relative to the target container, using `/` separators.
  final String path;

  /// Size, or null when the provider cannot report one.
  final int? sizeBytes;

  /// Lowercase hex SHA-256 of the entry's contents, or null when the provider cannot
  /// compute one. A null digest means identity cannot be proven, not that it matched.
  final String? sha256;

  /// Whether this entry is **provably** the file with [expectedSha256].
  ///
  /// Only an equal digest proves it. An equal size does not: two different files of the
  /// same length are ordinary, and treating them as the same entry would report a
  /// successful export for a file that is not there.
  bool isProvably({
    required String expectedSha256,
    required int expectedSizeBytes,
  }) =>
      sha256 != null &&
      sha256!.toLowerCase() == expectedSha256.toLowerCase() &&
      sizeBytes == expectedSizeBytes;
}

/// What the target container holds.
class TargetInventory {
  const TargetInventory.known(List<TargetEntry> this.entries);

  /// The provider could not list the target.
  const TargetInventory.unknown() : entries = null;

  final List<TargetEntry>? entries;

  bool get isKnown => entries != null;

  TargetEntry? entryAt(String path) {
    final List<TargetEntry>? known = entries;
    if (known == null) {
      return null;
    }
    for (final TargetEntry entry in known) {
      if (entry.path == path) {
        return entry;
      }
    }
    return null;
  }

  /// Every path the target holds, for conflict resolution.
  Set<String> get paths => <String>{
    for (final TargetEntry entry in entries ?? const <TargetEntry>[])
      entry.path,
  };
}

/// How the platform committed the target name.
class ExportCommitResult {
  const ExportCommitResult({required this.atomic});

  /// Whether the platform could make the name appear atomically.
  ///
  /// False is a legitimate answer - a document provider, a cross-filesystem copy or an
  /// in-place write cannot promise it. V2.1 §15 forbids calling that atomic, so it is
  /// reported rather than assumed.
  final bool atomic;
}

/// The platform port that writes to the user's target and frees the app's staging.
///
/// Deliberately has no way to delete, move or overwrite an entry at the target. See the
/// library comment: cancelling a task must never delete an exported file, and the
/// cheapest way to guarantee that is to not have the capability.
abstract class ExportSink {
  /// Lists what the target already holds.
  ///
  /// Returns [TargetInventory.unknown] rather than an empty list when it cannot tell the
  /// difference - the two lead to opposite decisions about whether it is safe to write.
  Future<TargetInventory> inventory({required String targetRef});

  /// Writes the file's verified bytes to [safePath] under [targetRef].
  ///
  /// Must not leave a partial file under the final name: a truncated file the user
  /// mistakes for their data is worse than a failed export, and the next attempt would
  /// see the name as taken.
  Future<ExportCommitResult> commit({
    required String fileId,
    required String targetRef,
    required String safePath,
  });

  /// Deletes the app's staging copy for [fileId].
  ///
  /// Only ever called for app-internal staging, and only after the export record is
  /// durable. Failing here costs disk space and nothing else.
  Future<void> deleteStaging({required String fileId});
}

/// What happened to the app's staging copy.
enum StagingRelease {
  /// Deleted; the space is reclaimed.
  freed,

  /// Deletion was attempted and failed. Only affects space (端侧设计 §7).
  failed,

  /// Nothing was attempted, because the export was not recorded. Staging is the only
  /// thing that could still produce the user's file, so it is kept.
  retained,

  /// There was nothing to release, because this file was already recorded as saved.
  notNeeded,
}

/// The result of one export attempt.
enum ExportOutcomeKind {
  /// The user's copy is at the target.
  saved,

  /// The naming policy left this file out; the queue continues.
  skipped,

  /// A conflict needs the user's decision.
  needsUserDecision,

  /// The service declined to proceed, because proceeding could not be shown to be safe.
  refused,

  /// The commit or the record failed. Retryable; staging is kept.
  failed,
}

/// What one export attempt produced.
class ExportOutcome {
  const ExportOutcome({
    required this.kind,
    required this.fileId,
    this.safePath,
    this.reason,
    this.wroteToTarget = false,
    this.committedAtomically,
    this.stagingRelease = StagingRelease.notNeeded,
    this.cleanupFailure,
  });

  final ExportOutcomeKind kind;
  final String fileId;

  /// Where the copy is, relative to the target. Set when [kind] is
  /// [ExportOutcomeKind.saved].
  final String? safePath;

  /// Why the attempt did not save, in terms safe to show.
  final String? reason;

  /// Whether this attempt wrote the bytes. False when it reused an entry that was
  /// already there, which is what stops a retry from duplicating the file.
  final bool wroteToTarget;

  /// Whether the platform could commit the name atomically. Null when nothing was
  /// committed.
  final bool? committedAtomically;

  final StagingRelease stagingRelease;

  /// Why staging was not freed. Space only; never a reason to call the export failed.
  final String? cleanupFailure;

  /// Whether the user's file is at the target.
  ///
  /// This is about the export alone: a failed staging release does not change it, because
  /// 端侧设计 §7 says a cleanup failure "只影响空间回收".
  bool get isSaved => kind == ExportOutcomeKind.saved;

  /// Whether retrying the same call could succeed.
  bool get isRetryable => kind == ExportOutcomeKind.failed;

  @override
  String toString() =>
      'ExportOutcome(${kind.name}, $fileId'
      '${safePath == null ? '' : ', $safePath'}'
      '${wroteToTarget ? ', wrote' : ', reused'}'
      ', staging=${stagingRelease.name})';
}

/// Places verified files at the user's target.
class ExportService {
  ExportService({
    required this.database,
    required this.sink,
    TransferRepository? transfers,
    this.naming = const ExportNamingPolicy(),
  }) : transfers = transfers ?? TransferRepository(database);

  final NearSendDatabase database;
  final ExportSink sink;
  final TransferRepository transfers;
  final ExportNamingPolicy naming;

  /// Exports one verified file.
  ///
  /// The order is the contract: inventory, plan, commit, **record**, release staging.
  /// [verification] must be an exportable receipt; [TransferRepository.recordSavedExport]
  /// enforces that, so a file that has not passed verification cannot reach the target
  /// through a recorded path.
  Future<ExportOutcome> exportFile({
    required String fileId,
    required String targetRef,
    required FileVerificationResult verification,
  }) async {
    final _FrozenTarget target = _readFrozen(fileId);

    // Already recorded for this target: the user has the file, so nothing is written and
    // a retry cannot produce a second copy.
    final ExportRecord? existing = transfers.existingExport(fileId);
    if (existing != null && existing.isSaved) {
      if (existing.targetUri == targetRef) {
        return ExportOutcome(
          kind: ExportOutcomeKind.saved,
          fileId: fileId,
          safePath: existing.savedPath ?? target.relativePath,
          stagingRelease: StagingRelease.notNeeded,
        );
      }
      return ExportOutcome(
        kind: ExportOutcomeKind.refused,
        fileId: fileId,
        reason:
            'this file was already saved to a different target; a second copy needs the '
            'user to confirm',
      );
    }

    final TargetInventory inventory = await sink.inventory(
      targetRef: targetRef,
    );
    if (!inventory.isKnown) {
      // Not "treat it as empty": an unlistable target may already hold the user's file
      // under the name we are about to write.
      return const ExportOutcome(
        kind: ExportOutcomeKind.refused,
        fileId: '',
      ).withFile(
        fileId,
        reason:
            'the target cannot be listed, so the app cannot tell whether the name is '
            'already taken; refusing rather than risking the user\'s file',
      );
    }

    // The name this file would take with no conflict at all. Used first to ask whether an
    // earlier attempt already put the copy there.
    final ExportTargetPlan natural = naming.plan(
      frozenRelativePath: target.relativePath,
      takenPaths: const <String>{},
    );
    if (natural.isPlanned) {
      final TargetEntry? there = inventory.entryAt(natural.safePath!);
      if (there != null &&
          there.isProvably(
            expectedSha256: target.fileSha256,
            expectedSizeBytes: target.sizeBytes,
          )) {
        // A previous attempt committed this exact file but did not get as far as the
        // record. Reuse it rather than writing a second copy (V2.1 §15).
        final ExportRecord record = transfers.recordSavedExport(
          fileId: fileId,
          targetUri: targetRef,
          verification: verification,
          savedPath: natural.safePath!,
        );
        return _releaseStaging(
          fileId: fileId,
          safePath: record.savedPath,
          wroteToTarget: false,
          committedAtomically: null,
        );
      }
    }

    final ExportTargetPlan plan = naming.plan(
      frozenRelativePath: target.relativePath,
      takenPaths: inventory.paths,
    );
    switch (plan.status) {
      case ExportTargetStatus.skipped:
        return ExportOutcome(
          kind: ExportOutcomeKind.skipped,
          fileId: fileId,
          reason: plan.reason,
          stagingRelease: StagingRelease.retained,
        );
      case ExportTargetStatus.needsUserDecision:
        return ExportOutcome(
          kind: ExportOutcomeKind.needsUserDecision,
          fileId: fileId,
          reason:
              'an entry named "${plan.conflictWith}" is already at the target',
          stagingRelease: StagingRelease.retained,
        );
      case ExportTargetStatus.planned:
        break;
    }

    final String safePath = plan.safePath!;
    late final ExportCommitResult committed;
    try {
      committed = await sink.commit(
        fileId: fileId,
        targetRef: targetRef,
        safePath: safePath,
      );
    } on Object catch (error) {
      return ExportOutcome(
        kind: ExportOutcomeKind.failed,
        fileId: fileId,
        safePath: safePath,
        reason: 'writing to the target failed: $error',
        stagingRelease: StagingRelease.retained,
      );
    }

    // The record is written before anything is released. If this fails the attempt is
    // reported as failed and staging survives, because without the record there is no
    // durable evidence the user has a copy.
    final ExportRecord record;
    try {
      record = transfers.recordSavedExport(
        fileId: fileId,
        targetUri: targetRef,
        verification: verification,
        savedPath: safePath,
      );
    } on Object catch (error) {
      return ExportOutcome(
        kind: ExportOutcomeKind.failed,
        fileId: fileId,
        safePath: safePath,
        reason: 'the copy was written but could not be recorded: $error',
        wroteToTarget: true,
        committedAtomically: committed.atomic,
        stagingRelease: StagingRelease.retained,
      );
    }

    return _releaseStaging(
      fileId: fileId,
      safePath: record.savedPath,
      wroteToTarget: true,
      committedAtomically: committed.atomic,
    );
  }

  /// Frees staging, without letting a failure change the export's outcome.
  ///
  /// 端侧设计 §7: a cleanup failure "只影响空间回收，不把已导出文件改为失败".
  Future<ExportOutcome> _releaseStaging({
    required String fileId,
    required String? safePath,
    required bool wroteToTarget,
    required bool? committedAtomically,
  }) async {
    try {
      await sink.deleteStaging(fileId: fileId);
      return ExportOutcome(
        kind: ExportOutcomeKind.saved,
        fileId: fileId,
        safePath: safePath,
        wroteToTarget: wroteToTarget,
        committedAtomically: committedAtomically,
        stagingRelease: StagingRelease.freed,
      );
    } on Object catch (error) {
      return ExportOutcome(
        kind: ExportOutcomeKind.saved,
        fileId: fileId,
        safePath: safePath,
        wroteToTarget: wroteToTarget,
        committedAtomically: committedAtomically,
        stagingRelease: StagingRelease.failed,
        cleanupFailure: '$error',
      );
    }
  }

  _FrozenTarget _readFrozen(String fileId) {
    final ResultSet rows = database.db.select(
      'SELECT relative_path, size_bytes, file_sha256 FROM files WHERE file_id = ?;',
      <Object?>[fileId],
    );
    if (rows.isEmpty) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'file $fileId is not registered',
      );
    }
    final Row row = rows.first;
    return _FrozenTarget(
      relativePath: row['relative_path'] as String,
      sizeBytes: row['size_bytes'] as int,
      fileSha256: row['file_sha256'] as String,
    );
  }
}

/// The frozen facts an export needs.
class _FrozenTarget {
  const _FrozenTarget({
    required this.relativePath,
    required this.sizeBytes,
    required this.fileSha256,
  });

  final String relativePath;
  final int sizeBytes;
  final String fileSha256;
}

extension on ExportOutcome {
  /// Rebuilds an outcome with a file id and reason, for the refusal raised before the id
  /// was in scope.
  ExportOutcome withFile(String fileId, {required String reason}) =>
      ExportOutcome(
        kind: kind,
        fileId: fileId,
        reason: reason,
        stagingRelease: stagingRelease,
      );
}
