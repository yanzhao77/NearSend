/// Schema migration framework, `docs/architecture/APP_AND_SERVICE_DESIGN.md` §10.
///
/// The rules the framework enforces, and why each one exists:
///
/// * **Monotonic versions.** A step is applied once, in order, and never skipped.
/// * **One transaction per step.** SQLite makes DDL transactional, so a failing step can
///   be rolled back completely. A half-migrated database is worse than an old one,
///   because the old one at least still opens.
/// * **Consistency backup before upgrading.** §10 forbids copying the main database file
///   while a WAL is active, which can capture a torn state. `VACUUM INTO` asks SQLite for
///   a consistent copy instead.
/// * **A newer schema is refused.** Downgrading by ignoring unknown structures corrupts
///   whatever the newer build wrote. Refusing keeps the user's data intact.
library;

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/storage/storage_failure.dart';
import 'package:nearsend/core/storage/storage_schema.dart';

/// One schema version's upgrade step.
class MigrationStep {
  const MigrationStep({
    required this.version,
    required this.description,
    required this.apply,
  });

  /// The version this step produces. Must be one greater than the step before it.
  final int version;

  /// Short description, used in diagnostics.
  final String description;

  /// Applies the step. Runs inside a transaction the runner controls, so it must not
  /// open or commit one itself.
  final void Function(Database db) apply;
}

/// The ordered set of known migrations.
abstract final class StorageMigrations {
  /// Every known step, ascending by version.
  ///
  /// Version 1 creates the initial schema. Later versions append here; they must never
  /// be edited in place, because a database in the field already ran the old version.
  static const List<MigrationStep> steps = <MigrationStep>[
    MigrationStep(
      version: 1,
      description:
          'initial schema: tasks, files, chunks, peers, idempotency, exports',
      apply: StorageSchema.applyVersion1,
    ),
    MigrationStep(
      version: 2,
      description: 'exports remembers the name a saved copy was written under',
      apply: StorageSchema.applyVersion2,
    ),
    MigrationStep(
      version: 3,
      description:
          'tasks remembers the last committed checkpoint sequence (§8)',
      apply: StorageSchema.applyVersion3,
    ),
    MigrationStep(
      version: 4,
      description:
          'manifest staging is persisted: staging, file pages and chunk pages (ADR-0004)',
      apply: StorageSchema.applyVersion4,
    ),
    MigrationStep(
      version: 5,
      description:
          'task credentials by digest, and the receiver authorisation record (§3, §6)',
      apply: StorageSchema.applyVersion5,
    ),
    MigrationStep(
      version: 6,
      description:
          'a sending task remembers where it reads each file from (§7 chunk GET)',
      apply: StorageSchema.applyVersion6,
    ),
    MigrationStep(
      version: 7,
      description:
          'non-secret application settings are persisted separately from credentials',
      apply: StorageSchema.applyVersion7,
    ),
  ];

  /// The version a fresh database reaches by applying every step.
  static int get targetVersion => steps.isEmpty
      ? 0
      : steps.map((MigrationStep s) => s.version).reduce(_max);

  /// Validates a step table, so a mistake fails loudly instead of producing a database
  /// that is subtly half-upgraded.
  ///
  /// Takes the list rather than reading the static one, so tests can drive the runner
  /// with a deliberately broken or failing step.
  static void assertWellFormed(List<MigrationStep> steps) {
    if (steps.isEmpty) {
      throw const StorageException(
        StorageFailureCode.migrationFailed,
        'no migration steps are registered',
      );
    }
    for (int i = 0; i < steps.length; i++) {
      final int expected = i + 1;
      if (steps[i].version != expected) {
        throw StorageException(
          StorageFailureCode.migrationFailed,
          'migration steps must be contiguous from 1; index $i declares version '
          '${steps[i].version}',
        );
      }
    }
    final int target = steps.map((MigrationStep s) => s.version).reduce(_max);
    if (target != StorageSchema.currentVersion) {
      throw StorageException(
        StorageFailureCode.migrationFailed,
        'the registered steps reach version $target but the schema constant is '
        '${StorageSchema.currentVersion}',
      );
    }
  }

  static int _max(int a, int b) => a > b ? a : b;
}

/// Reads and writes the schema version row, and applies migrations.
class StorageMigrator {
  StorageMigrator({this.now = _systemNow, List<MigrationStep>? steps})
    : steps = steps ?? StorageMigrations.steps;

  /// Clock injection so tests do not depend on wall time.
  final int Function() now;

  /// The steps to apply. Injectable so a test can supply a step that fails and prove the
  /// database is left at its previous version.
  final List<MigrationStep> steps;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  /// The stored schema version, or 0 when the database has no metadata table yet.
  int storedVersion(Database db) {
    final bool hasMeta = db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?;",
      <Object?>[StorageSchema.metaTable],
    ).isNotEmpty;
    if (!hasMeta) {
      return 0;
    }
    final ResultSet rows = db.select(
      'SELECT version FROM ${StorageSchema.metaTable} WHERE id = 1;',
    );
    if (rows.isEmpty) {
      return 0;
    }
    return rows.first['version'] as int;
  }

  /// Brings [db] up to [StorageSchema.currentVersion], or refuses.
  ///
  /// Returns the version the database is at afterwards. [backupDirectory] receives a
  /// consistency backup before an existing database is upgraded; a fresh database needs
  /// none, because there is nothing to lose.
  int migrate(Database db, {String? backupDirectory}) {
    StorageMigrations.assertWellFormed(steps);

    final int from = storedVersion(db);

    if (from > StorageSchema.currentVersion) {
      throw StorageException(
        StorageFailureCode.schemaTooNew,
        'stored schema version $from is newer than this build supports '
        '(${StorageSchema.currentVersion}); refusing to open for writing',
      );
    }

    if (from == StorageSchema.currentVersion) {
      return from;
    }

    if (from > 0 && backupDirectory != null) {
      writeBackup(db, backupDirectory, from);
    }

    for (final MigrationStep step in steps) {
      if (step.version <= from) {
        continue;
      }
      _applyStep(db, step);
    }

    return StorageSchema.currentVersion;
  }

  void _applyStep(Database db, MigrationStep step) {
    db.execute('BEGIN IMMEDIATE;');
    try {
      step.apply(db);
      db.execute(
        'INSERT INTO ${StorageSchema.metaTable} (id, version, applied_at) '
        'VALUES (1, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET version = excluded.version, '
        'applied_at = excluded.applied_at;',
        <Object?>[step.version, now()],
      );
      db.execute('COMMIT;');
    } on Object catch (error) {
      // Roll back so the database stays at the previous version rather than becoming a
      // mixture of two schemas. SQLite rolls DDL back with the transaction.
      try {
        db.execute('ROLLBACK;');
      } on SqliteException {
        // The transaction was already aborted; the rollback is best effort.
      }
      throw StorageException(
        StorageFailureCode.migrationFailed,
        'migration to version ${step.version} (${step.description}) failed',
        cause: error,
      );
    }
  }

  /// Writes a consistent copy of [db] into [directory]. Public so a test can exercise
  /// it directly, since a single-step history cannot otherwise reach the upgrade path.
  ///
  /// Uses `VACUUM INTO` rather than copying the file: §10 warns that copying the main
  /// file while a WAL is active can capture a torn state, and a backup that cannot be
  /// restored is worse than no backup because it invites confidence.
  void writeBackup(Database db, String directory, int fromVersion) {
    final Directory dir = Directory(directory);
    final String target =
        '${dir.path}${Platform.pathSeparator}nearsend-pre-migration-v$fromVersion.db';
    try {
      // Directory creation is inside the try on purpose: a filesystem failure here is
      // just as much a backup failure, and letting it escape as a raw PathExistsException
      // would give the caller an untyped error for the one condition they are meant to
      // handle.
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      if (File(target).existsSync()) {
        File(target).deleteSync();
      }
      // VACUUM INTO quotes its argument as a SQL string literal; a path containing a
      // single quote would break out of it, so it is escaped rather than interpolated
      // blindly.
      db.execute("VACUUM INTO '${target.replaceAll("'", "''")}';");
    } on Object catch (error) {
      throw StorageException(
        StorageFailureCode.backupFailed,
        'could not write the pre-migration backup to $target',
        cause: error,
      );
    }
  }
}
