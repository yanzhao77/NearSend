import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_failure.dart';
import 'package:nearsend/core/storage/storage_migrations.dart';
import 'package:nearsend/core/storage/storage_schema.dart';

/// Schema versioning, migration, rollback and the refusal of a newer schema.
///
/// `docs/architecture/APP_AND_SERVICE_DESIGN.md` §10 requires each of these, and the
/// project rules make an unrecoverable migration a release blocker, so the failure paths
/// are tested as carefully as the happy one.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('nearsend-migration-'));
  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  String dbPath(String name) => '${dir.path}${Platform.pathSeparator}$name';

  group('fresh database', () {
    test('is created at the current version with every table', () {
      final NearSendDatabase db = NearSendDatabase.open(
        path: dbPath('fresh.db'),
      );
      try {
        expect(db.schemaVersion, StorageSchema.currentVersion);

        final Set<String> tables = <String>{
          for (final Row row in db.db.select(
            "SELECT name FROM sqlite_master WHERE type = 'table';",
          ))
            row['name'] as String,
        };
        expect(
          tables.containsAll(StorageSchema.tableNames),
          isTrue,
          reason: 'missing: ${StorageSchema.tableNames.difference(tables)}',
        );
      } finally {
        db.close();
      }
    });

    test('reopening is idempotent and does not re-run the migration', () {
      final String path = dbPath('reopen.db');
      final NearSendDatabase first = NearSendDatabase.open(path: path);
      try {
        first.db.execute(
          "INSERT INTO peers (peer_id, identity_fingerprint, authorized) "
          "VALUES ('p1', 'fp', 1);",
        );
      } finally {
        first.close();
      }

      final NearSendDatabase second = NearSendDatabase.open(path: path);
      try {
        expect(second.schemaVersion, StorageSchema.currentVersion);
        // The row survived, so the migration did not drop and recreate the schema.
        expect(
          second.db.select('SELECT COUNT(*) AS c FROM peers;').first['c'],
          1,
        );
      } finally {
        second.close();
      }
    });

    test('an in-memory database opens without a file', () {
      final NearSendDatabase db = NearSendDatabase.open(
        path: NearSendDatabase.inMemoryPath,
      );
      try {
        expect(db.schemaVersion, StorageSchema.currentVersion);
      } finally {
        db.close();
      }
    });
  });

  group('a newer schema is refused without modifying the file', () {
    test('opening a version-99 database throws schemaTooNew', () {
      final String path = dbPath('newer.db');

      // Build a database from the future, by hand.
      final Database raw = sqlite3.open(path);
      raw.execute(StorageSchema.createMetaTable);
      raw.execute(
        'INSERT INTO ${StorageSchema.metaTable} (id, version, applied_at) '
        'VALUES (1, 99, 0);',
      );
      raw.close();

      expect(
        () => NearSendDatabase.open(path: path),
        throwsA(
          isA<StorageException>().having(
            (StorageException e) => e.code,
            'code',
            StorageFailureCode.schemaTooNew,
          ),
        ),
      );

      // The refusal must not have touched the file. journal_mode is stored in the
      // database header, unlike synchronous and foreign_keys which are per-connection,
      // so it is the observable proof that no write happened.
      final Database check = sqlite3.open(path);
      try {
        expect(
          check.select('PRAGMA journal_mode;').first.values.first,
          'delete',
          reason: 'the refusal must not have switched the file to WAL',
        );
        expect(
          check
              .select('SELECT version FROM ${StorageSchema.metaTable};')
              .first['version'],
          99,
          reason: 'the stored version must be untouched',
        );
      } finally {
        check.close();
      }
    });

    test('the migrator refuses a newer version before applying anything', () {
      final Database raw = sqlite3.openInMemory();
      try {
        raw.execute(StorageSchema.createMetaTable);
        raw.execute(
          'INSERT INTO ${StorageSchema.metaTable} (id, version, applied_at) '
          'VALUES (1, 42, 0);',
        );
        expect(
          () => StorageMigrator().migrate(raw),
          throwsA(
            isA<StorageException>().having(
              (StorageException e) => e.code,
              'code',
              StorageFailureCode.schemaTooNew,
            ),
          ),
        );
        // Still 42: a refusal is not a downgrade.
        expect(StorageMigrator().storedVersion(raw), 42);
      } finally {
        raw.close();
      }
    });
  });

  group('a failing migration rolls back', () {
    test('the database is left at version 0 with no partial schema', () {
      final String path = dbPath('failing.db');
      final Database db = sqlite3.open(path);

      final StorageMigrator migrator = StorageMigrator(
        steps: <MigrationStep>[
          MigrationStep(
            version: 1,
            description: 'deliberately fails after creating a table',
            apply: (Database handle) {
              handle.execute('CREATE TABLE half_applied (v TEXT);');
              throw StateError('injected migration failure');
            },
          ),
        ],
      );

      try {
        expect(
          () => migrator.migrate(db),
          throwsA(
            isA<StorageException>().having(
              (StorageException e) => e.code,
              'code',
              StorageFailureCode.migrationFailed,
            ),
          ),
        );

        expect(
          migrator.storedVersion(db),
          0,
          reason: 'the version must not advance when the step failed',
        );
        expect(
          db
              .select(
                "SELECT name FROM sqlite_master WHERE type = 'table' "
                "AND name = 'half_applied';",
              )
              .isEmpty,
          isTrue,
          reason:
              'SQLite makes DDL transactional, so the table created inside the failed '
              'step must not survive',
        );
      } finally {
        db.close();
      }
    });

    test('a successful retry after a failure reaches the current version', () {
      final String path = dbPath('retry.db');
      final Database db = sqlite3.open(path);
      try {
        final StorageMigrator broken = StorageMigrator(
          steps: <MigrationStep>[
            MigrationStep(
              version: 1,
              description: 'fails',
              apply: (Database handle) => throw StateError('injected'),
            ),
          ],
        );
        expect(() => broken.migrate(db), throwsA(isA<StorageException>()));

        // The real migrator must still work on the same database: a rolled back
        // migration leaves a database that can be upgraded again, not a poisoned one.
        expect(StorageMigrator().migrate(db), StorageSchema.currentVersion);
      } finally {
        db.close();
      }
    });
  });

  group('pre-migration backup', () {
    test('writes a consistent copy that contains the original data', () {
      final Database db = sqlite3.open(dbPath('backup-source.db'));
      try {
        db.execute('PRAGMA journal_mode = WAL;');
        db.execute('CREATE TABLE marker (v TEXT);');
        db.execute("INSERT INTO marker (v) VALUES ('before-migration');");

        final String backupDir = '${dir.path}${Platform.pathSeparator}backups';
        StorageMigrator().writeBackup(db, backupDir, 1);

        final String expected =
            '$backupDir${Platform.pathSeparator}nearsend-pre-migration-v1.db';
        expect(File(expected).existsSync(), isTrue);

        // The copy must be openable and carry the data: a backup that cannot be restored
        // is worse than none, because it invites confidence.
        final Database restored = sqlite3.open(expected);
        try {
          expect(
            restored.select('SELECT v FROM marker;').first['v'],
            'before-migration',
          );
        } finally {
          restored.close();
        }
      } finally {
        db.close();
      }
    });

    test(
      'an unwritable destination is reported as backupFailed, not ignored',
      () {
        final Database db = sqlite3.open(dbPath('backup-fail.db'));
        try {
          db.execute('CREATE TABLE marker (v TEXT);');
          // A path under a regular file cannot be a directory.
          final String blocker = '${dir.path}${Platform.pathSeparator}blocker';
          File(blocker).writeAsStringSync('not a directory');

          expect(
            () => StorageMigrator().writeBackup(db, blocker, 1),
            throwsA(
              isA<StorageException>().having(
                (StorageException e) => e.code,
                'code',
                StorageFailureCode.backupFailed,
              ),
            ),
          );
        } finally {
          db.close();
        }
      },
    );
  });

  group('the migration table itself', () {
    test('accepts the real registry', () {
      expect(
        () => StorageMigrations.assertWellFormed(StorageMigrations.steps),
        returnsNormally,
      );
      expect(StorageMigrations.targetVersion, StorageSchema.currentVersion);
    });

    test('rejects a gap in the version sequence', () {
      expect(
        () => StorageMigrations.assertWellFormed(<MigrationStep>[
          const MigrationStep(version: 1, description: 'a', apply: _noop),
          const MigrationStep(version: 3, description: 'c', apply: _noop),
        ]),
        throwsA(
          isA<StorageException>().having(
            (StorageException e) => e.code,
            'code',
            StorageFailureCode.migrationFailed,
          ),
        ),
      );
    });

    test('rejects an empty registry', () {
      expect(
        () => StorageMigrations.assertWellFormed(const <MigrationStep>[]),
        throwsA(isA<StorageException>()),
      );
    });

    test('rejects a registry that does not reach the schema constant', () {
      expect(
        () => StorageMigrations.assertWellFormed(<MigrationStep>[
          const MigrationStep(version: 1, description: 'a', apply: _noop),
          const MigrationStep(version: 2, description: 'b', apply: _noop),
        ]),
        throwsA(
          isA<StorageException>().having(
            (StorageException e) => e.detail,
            'detail',
            contains('schema constant'),
          ),
        ),
      );
    });
  });

  group('storage failure codes', () {
    test('only a failed commit is retryable', () {
      for (final StorageFailureCode code in StorageFailureCode.values) {
        expect(
          code.retryable,
          code == StorageFailureCode.commitFailed,
          reason: '${code.name} retryability',
        );
      }
    });

    test('local codes map to a wire code only where one honestly applies', () {
      expect(
        StorageFailureCode.staleLease.protocolCode?.wireCode,
        'STALE_LEASE',
      );
      expect(
        StorageFailureCode.commitFailed.protocolCode?.wireCode,
        'DB_COMMIT_FAILED',
      );
      expect(
        StorageFailureCode.schemaTooNew.protocolCode,
        isNull,
        reason: 'a newer local schema never reaches the peer',
      );
      expect(StorageFailureCode.backupFailed.protocolCode, isNull);
    });

    test('every code has a stable diagnostic code and a message key', () {
      final Set<String> codes = <String>{};
      for (final StorageFailureCode code in StorageFailureCode.values) {
        expect(code.code, startsWith('NS-STORAGE-'));
        expect(code.messageKey, startsWith('storage.'));
        expect(codes.add(code.code), isTrue);
      }
    });
  });
}

void _noop(Database db) {}
