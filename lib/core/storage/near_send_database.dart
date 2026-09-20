/// Opening and transaction handling for the receiver's database.
///
/// ## Ordering matters for the refusal path
///
/// `PRAGMA journal_mode = WAL` is recorded **in the database file**, unlike
/// `synchronous` and `foreign_keys`, which are per-connection. So the schema version is
/// read *before* any pragma is applied: a database written by a newer build must be
/// refused without this build having modified it at all. Applying WAL first and then
/// refusing would already have changed the file.
library;

import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/storage/storage_failure.dart';
import 'package:nearsend/core/storage/storage_migrations.dart';
import 'package:nearsend/core/storage/storage_schema.dart';

/// A handle to the receiver's database.
class NearSendDatabase {
  NearSendDatabase._(this.db, {required this.schemaVersion});

  /// The underlying connection.
  final Database db;

  /// The schema version the database is at after opening.
  final int schemaVersion;

  /// The path used for an in-memory database, which is what tests use.
  static const String inMemoryPath = ':memory:';

  /// Opens [path], refusing a database written by a newer build.
  ///
  /// [backupDirectory] receives a consistency backup when an existing database is
  /// upgraded. Pass null to skip the backup, which is only appropriate for a throwaway
  /// database.
  static NearSendDatabase open({
    required String path,
    String? backupDirectory,
    StorageMigrator? migrator,
  }) {
    final bool isMemory = path == inMemoryPath;
    final Database db = sqlite3.open(path);
    try {
      final StorageMigrator effective = migrator ?? StorageMigrator();

      // Read-only check first: see the note at the top of this file.
      final int existing = effective.storedVersion(db);
      if (existing > StorageSchema.currentVersion) {
        throw StorageException(
          StorageFailureCode.schemaTooNew,
          'stored schema version $existing is newer than this build supports '
          '(${StorageSchema.currentVersion}); refusing to open for writing',
        );
      }

      if (!isMemory) {
        // WAL lets a checkpoint commit without blocking readers.
        db.execute('PRAGMA journal_mode = WAL;');
      }
      // synchronous=FULL is what the receiver's "durable sync, then commit" ordering
      // relies on. The binding probe asserts it reads back as 2, so a silent downgrade
      // fails a test rather than corrupting recovery.
      db.execute('PRAGMA synchronous = FULL;');
      db.execute('PRAGMA foreign_keys = ON;');
      db.execute('PRAGMA busy_timeout = 5000;');

      final int version = effective.migrate(
        db,
        backupDirectory: backupDirectory,
      );
      return NearSendDatabase._(db, schemaVersion: version);
    } on Object {
      db.close();
      rethrow;
    }
  }

  /// Closes the connection.
  void close() => db.close();

  /// Runs [body] inside an immediate transaction.
  ///
  /// `BEGIN IMMEDIATE` takes the write lock up front, so a write that cannot proceed
  /// fails immediately instead of after doing work that must then be discarded.
  ///
  /// Rolls back and rethrows on any failure. A caller that sees an exception can rely on
  /// nothing from [body] having been committed, which is what lets a chunk be retried
  /// instead of being reported as acknowledged.
  ///
  /// A [StorageException] and a [ProtocolViolation] both pass through unchanged. The
  /// violation case matters: a body that refuses an undefined state transition is
  /// reporting a protocol error, and relabelling it as `NS-STORAGE-*` would tell the
  /// caller the disk failed when the protocol did. Only genuinely unexpected errors are
  /// wrapped, and the original is kept as `cause`.
  T transaction<T>(T Function() body) {
    db.execute('BEGIN IMMEDIATE;');
    try {
      final T result = body();
      db.execute('COMMIT;');
      return result;
    } on Object catch (error) {
      _rollbackQuietly();
      if (error is StorageException || error is ProtocolViolation) {
        rethrow;
      }
      throw _classify(error, 'transaction');
    }
  }

  /// Runs [body] inside a deferred (read) transaction.
  T readTransaction<T>(T Function() body) {
    db.execute('BEGIN;');
    try {
      final T result = body();
      db.execute('COMMIT;');
      return result;
    } on Object catch (error) {
      _rollbackQuietly();
      if (error is StorageException || error is ProtocolViolation) {
        rethrow;
      }
      throw _classify(error, 'read transaction');
    }
  }

  /// Turns an unexpected error into a storage failure with an honest code.
  ///
  /// `SQLITE_FULL` is singled out because it is the one engine error whose remedy is not
  /// "try again": §11 gives `SPACE_INSUFFICIENT` the remedy "free space or change
  /// location, then retry" and marks it not retryable. Reporting exhaustion as
  /// [StorageFailureCode.commitFailed] would set `retryable: true` and let a client
  /// retry forever against a volume that cannot accept the write.
  ///
  /// Only the primary result code is compared. SQLite's extended codes pack the primary
  /// code in the low byte, so `resultCode` already matches for every `SQLITE_FULL`
  /// variant, and no code is mapped that a test has not actually produced.
  static StorageException _classify(Object error, String context) {
    if (error is SqliteException && error.resultCode == _sqliteFull) {
      return StorageException(
        StorageFailureCode.spaceInsufficient,
        'the database could not grow: the volume is out of space',
        cause: error,
      );
    }
    return StorageException(
      StorageFailureCode.commitFailed,
      '$context rolled back',
      cause: error,
    );
  }

  /// SQLite's primary result code for "database or disk is full".
  static const int _sqliteFull = 13;

  void _rollbackQuietly() {
    try {
      db.execute('ROLLBACK;');
    } on SqliteException {
      // The transaction was already aborted by SQLite; nothing left to undo.
    }
  }
}
