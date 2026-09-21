import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/protocol/protocol_exception.dart';
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
      // Expressed in terms of the constant so the test keeps its meaning when a version
      // is added: the point is "one short of what the schema claims", not "two steps".
      final List<MigrationStep> short = <MigrationStep>[
        for (int i = 1; i < StorageSchema.currentVersion; i++)
          MigrationStep(version: i, description: 'step $i', apply: _noop),
      ];
      expect(
        short,
        isNotEmpty,
        reason: 'the schema must claim at least two versions',
      );

      expect(
        () => StorageMigrations.assertWellFormed(short),
        throwsA(
          isA<StorageException>().having(
            (StorageException e) => e.detail,
            'detail',
            contains('schema constant'),
          ),
        ),
      );
    });

    test('rejects a registry that goes past the schema constant', () {
      final List<MigrationStep> over = <MigrationStep>[
        for (int i = 1; i <= StorageSchema.currentVersion + 1; i++)
          MigrationStep(version: i, description: 'step $i', apply: _noop),
      ];

      expect(
        () => StorageMigrations.assertWellFormed(over),
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

  group('upgrading a version 1 database', () {
    /// Builds a database at version 1 only, as the version 1 build would have left it.
    ///
    /// The step is applied directly rather than through [StorageMigrator], deliberately:
    /// the migrator requires its registry to reach the current schema constant, which is
    /// the right invariant for a shipped registry and the wrong one for reconstructing a
    /// historical database. Relaxing it to make this test possible would trade a real
    /// guard for test convenience.
    Database openVersionOne(String name) {
      final Database db = sqlite3.open(dbPath(name));
      db.execute('PRAGMA foreign_keys = ON;');
      StorageSchema.applyVersion1(db);
      db.execute(
        'INSERT INTO ${StorageSchema.metaTable} (id, version, applied_at) '
        'VALUES (1, 1, 0);',
      );
      return db;
    }

    /// Builds a database at exactly version 2, by running the real version 2 step.
    ///
    /// Reconstructed rather than hand-written for the same reason as [openVersionOne]: a
    /// hand-written "version 2" would be a guess at history, and the migration runner is
    /// entitled to refuse a registry that does not reach the current constant.
    Database openVersionTwo(String name) {
      final Database db = openVersionOne(name);
      StorageSchema.applyVersion2(db);
      db.execute(
        'UPDATE ${StorageSchema.metaTable} SET version = 2 WHERE id = 1;',
      );
      return db;
    }

    /// Builds a database at exactly version 3, by running the real version 3 step.
    ///
    /// This is the version that already exists in the field, so it is the one the staging
    /// upgrade (version 4) and the credential upgrade (version 5) actually meet.
    Database openVersionThree(String name) {
      final Database db = openVersionTwo(name);
      StorageSchema.applyVersion3(db);
      db.execute(
        'UPDATE ${StorageSchema.metaTable} SET version = 3 WHERE id = 1;',
      );
      return db;
    }

    test('reaches the current version', () {
      final Database db = openVersionOne('v1.db');
      try {
        expect(StorageMigrator().storedVersion(db), 1);
        expect(StorageMigrator().migrate(db), StorageSchema.currentVersion);
        expect(
          StorageMigrator().storedVersion(db),
          StorageSchema.currentVersion,
        );
      } finally {
        db.close();
      }
    });

    test('keeps the rows the old version wrote', () {
      final Database db = openVersionOne('v1-rows.db');
      try {
        db.execute(
          "INSERT INTO tasks (task_id, role, direction, state, protocol_major, "
          "protocol_minor, lease_epoch, created_at, updated_at) "
          "VALUES ('t1', 'receiver', 'client_to_server', 'ready', 1, 0, 0, 1, 1);",
        );
        db.execute(
          "INSERT INTO files (file_id, task_id, relative_path, size_bytes, "
          "chunk_size_bytes, chunk_count, file_sha256, chunk_manifest_digest, "
          "export_state, created_at) "
          "VALUES ('f1', 't1', 'a/b.bin', 4, 4, 1, 'aa', 'bb', 'completed', 1);",
        );
        // Written the version 1 way, which had no saved_path column.
        db.execute(
          "INSERT INTO exports (file_id, target_uri, result, recorded_at) "
          "VALUES ('f1', 'content://old', 'saved', 7);",
        );

        StorageMigrator().migrate(db);

        final Row task = db.select('SELECT * FROM tasks;').first;
        expect(task['task_id'], 't1');
        expect(task['state'], 'ready');

        final Row export = db.select('SELECT * FROM exports;').first;
        expect(export['target_uri'], 'content://old');
        expect(export['result'], 'saved');
        expect(export['recorded_at'], 7);
      } finally {
        db.close();
      }
    });

    test('an old export row has no name rather than an invented one', () {
      final Database db = openVersionOne('v1-null.db');
      try {
        db.execute(
          "INSERT INTO tasks (task_id, role, direction, state, protocol_major, "
          "protocol_minor, lease_epoch, created_at, updated_at) "
          "VALUES ('t1', 'receiver', 'client_to_server', 'ready', 1, 0, 0, 1, 1);",
        );
        db.execute(
          "INSERT INTO files (file_id, task_id, relative_path, size_bytes, "
          "chunk_size_bytes, chunk_count, file_sha256, chunk_manifest_digest, "
          "export_state, created_at) "
          "VALUES ('f1', 't1', 'a/b.bin', 4, 4, 1, 'aa', 'bb', 'completed', 1);",
        );
        db.execute(
          "INSERT INTO exports (file_id, target_uri, result, recorded_at) "
          "VALUES ('f1', 'content://old', 'saved', 7);",
        );

        StorageMigrator().migrate(db);

        expect(
          db.select('SELECT saved_path FROM exports;').first['saved_path'],
          isNull,
          reason:
              'the version 1 build genuinely did not record which name it used, and the '
              'copy may have been renamed to avoid overwriting something',
        );
      } finally {
        db.close();
      }
    });

    test('a backup is written before the upgrade', () {
      final Database db = openVersionOne('v1-backup.db');
      try {
        db.execute(
          "INSERT INTO peers (peer_id, identity_fingerprint, authorized) "
          "VALUES ('p1', 'fp', 1);",
        );
        final String backupDir = '${dir.path}${Platform.pathSeparator}backup';

        StorageMigrator().migrate(db, backupDirectory: backupDir);

        final List<File> backups = Directory(backupDir)
            .listSync()
            .whereType<File>()
            .toList();
        expect(backups, hasLength(1));
        expect(
          backups.single.path,
          contains('v1'),
          reason: 'the backup names the version it came from',
        );

        // The backup is a readable database that still holds the old row.
        final Database restored = sqlite3.open(backups.single.path);
        try {
          expect(
            restored.select('SELECT COUNT(*) AS c FROM peers;').first['c'],
            1,
          );
        } finally {
          restored.close();
        }
      } finally {
        db.close();
      }
    });

    test('the upgraded database can store a name afterwards', () {
      final Database db = openVersionOne('v1-write.db');
      try {
        db.execute(
          "INSERT INTO tasks (task_id, role, direction, state, protocol_major, "
          "protocol_minor, lease_epoch, created_at, updated_at) "
          "VALUES ('t1', 'receiver', 'client_to_server', 'ready', 1, 0, 0, 1, 1);",
        );
        db.execute(
          "INSERT INTO files (file_id, task_id, relative_path, size_bytes, "
          "chunk_size_bytes, chunk_count, file_sha256, chunk_manifest_digest, "
          "export_state, created_at) "
          "VALUES ('f1', 't1', 'a/b.bin', 4, 4, 1, 'aa', 'bb', 'completed', 1);",
        );

        StorageMigrator().migrate(db);
        db.execute(
          "INSERT INTO exports (file_id, target_uri, result, recorded_at, saved_path) "
          "VALUES ('f1', 'content://new', 'saved', 9, 'a/b (1).bin');",
        );

        expect(
          db.select('SELECT saved_path FROM exports;').first['saved_path'],
          'a/b (1).bin',
        );
      } finally {
        db.close();
      }
    });

    test('a version 2 database gains the checkpoint column at 0', () {
      // The checkpoint counter arrives in version 3. A task that existed before it has
      // legitimately taken no checkpoint, and 0 is what that means; defaulting to 1 or
      // copying some other number would claim a checkpoint was recorded when none was.
      final Database db = openVersionTwo('v2-checkpoint.db');
      try {
        db.execute(
          "INSERT INTO tasks (task_id, role, direction, state, protocol_major, "
          "protocol_minor, lease_epoch, created_at, updated_at) "
          "VALUES ('t1', 'receiver', 'client_to_server', 'ready', 1, 0, 3, 1, 1);",
        );

        expect(StorageMigrator().migrate(db), StorageSchema.currentVersion);
        expect(
          db
              .select(
                'SELECT ${StorageSchema.tasksCheckpointSeqColumn} AS seq FROM tasks;',
              )
              .first['seq'],
          0,
          reason:
              'the pre-existing task is at sequence 0, not a fabricated one',
        );
        expect(
          db.select('SELECT lease_epoch FROM tasks;').first['lease_epoch'],
          3,
          reason: 'the upgrade must not disturb the write generation',
        );
      } finally {
        db.close();
      }
    });

    test('the checkpoint column refuses a null', () {
      // NOT NULL with a default is what makes "no checkpoint yet" a value rather than an
      // absence, so a writer cannot leave the counter undefined.
      final Database db = openVersionTwo('v2-not-null.db');
      try {
        StorageMigrator().migrate(db);
        db.execute(
          "INSERT INTO tasks (task_id, role, direction, state, protocol_major, "
          "protocol_minor, created_at, updated_at) "
          "VALUES ('t1', 'receiver', 'client_to_server', 'ready', 1, 0, 1, 1);",
        );
        expect(
          () => db.execute(
            'UPDATE tasks SET ${StorageSchema.tasksCheckpointSeqColumn} = NULL;',
          ),
          throwsA(isA<SqliteException>()),
        );
      } finally {
        db.close();
      }
    });

    test('a version 3 database gains the staging tables without losing rows', () {
      // Version 4 is the upgrade a field database actually meets, so what matters is that it
      // adds the manifest staging tables and rewrites nothing else.
      final Database db = openVersionThree('v3-staging.db');
      try {
        db.execute(
          "INSERT INTO tasks (task_id, role, direction, state, protocol_major, "
          "protocol_minor, lease_epoch, manifest_digest, created_at, updated_at) "
          "VALUES ('t1', 'receiver', 'client_to_server', 'staging', 1, 0, 0, 'aa', 1, 1);",
        );

        expect(StorageMigrator().storedVersion(db), 3);
        StorageMigrator().migrate(db);
        expect(
          StorageMigrator().storedVersion(db),
          StorageSchema.currentVersion,
        );

        expect(
          db.select('SELECT task_id, state FROM tasks;').first['state'],
          'staging',
        );
        for (final String table in <String>[
          StorageSchema.manifestStagingTable,
          StorageSchema.manifestFilesTable,
          StorageSchema.manifestChunksTable,
          StorageSchema.taskCredentialsTable,
          StorageSchema.taskAuthorizationsTable,
        ]) {
          expect(
            db.select('PRAGMA table_info($table);'),
            isNotEmpty,
            reason: '$table must exist after the upgrade',
          );
        }

        // The staging row can be written against the upgraded schema, which is what
        // "the upgrade produced a usable database" means rather than "the DDL ran".
        db.execute(
          "INSERT INTO ${StorageSchema.manifestStagingTable} (transfer_id, "
          "manifest_digest, protocol_major, protocol_minor, created_at) "
          "VALUES ('t1', 'aa', 1, 0, 5);",
        );
        expect(
          db.select(
            'SELECT transfer_id FROM ${StorageSchema.manifestStagingTable};',
          ),
          hasLength(1),
        );
      } finally {
        db.close();
      }
    });

    test('the new staging tables require a registered task', () {
      // The foreign key is what stops a staging row from outliving the transfer it belongs
      // to, and it is checked by the engine because `foreign_keys` is on for every connection.
      final NearSendDatabase fresh = NearSendDatabase.open(
        path: dbPath('staging-fk.db'),
      );
      try {
        expect(
          () => fresh.db.execute(
            "INSERT INTO ${StorageSchema.manifestStagingTable} (transfer_id, "
            "manifest_digest, protocol_major, protocol_minor, created_at) "
            "VALUES ('absent', 'aa', 1, 0, 5);",
          ),
          throwsA(isA<SqliteException>()),
        );
      } finally {
        fresh.close();
      }
    });

    test('a fresh database and an upgraded one have the same columns', () {
      final Database upgraded = openVersionOne('same-upgraded.db');
      final NearSendDatabase fresh = NearSendDatabase.open(
        path: dbPath('same-fresh.db'),
      );
      try {
        StorageMigrator().migrate(upgraded);

        Set<String> columnsOf(Database db, String table) => <String>{
          for (final Row row in db.select('PRAGMA table_info($table);'))
            row['name'] as String,
        };

        for (final String table in StorageSchema.tableNames) {
          if (table == StorageSchema.metaTable) {
            continue;
          }
          expect(
            columnsOf(upgraded, table),
            columnsOf(fresh.db, table),
            reason:
                'a fresh database runs every step from 1, so it must end up with exactly '
                'what an upgraded one has for $table',
          );
        }
      } finally {
        upgraded.close();
        fresh.close();
      }
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
        StorageFailureCode.spaceInsufficient.protocolCode?.wireCode,
        'SPACE_INSUFFICIENT',
        reason:
            'an exhausted volume is the case §11 answers with 507 and a user action, so '
            'it must not be reported as a retryable DB_COMMIT_FAILED',
      );
      expect(
        StorageFailureCode.spaceInsufficient.protocolCode?.httpStatus,
        507,
      );
      expect(StorageFailureCode.spaceInsufficient.retryable, isFalse);
      expect(
        StorageFailureCode.syncReceiptMismatch.protocolCode,
        ProtocolErrorCode.chunkHashMismatch,
        reason:
            '§8 names CHUNK_HASH_MISMATCH for bytes that disagree with the frozen manifest, '
            'including on a resend of an already committed block; leaving it unmapped made '
            'toProtocolError fall back to DB_COMMIT_FAILED, which is retryable and would '
            'invite the resend §11 forbids',
      );
      expect(
        StorageFailureCode.syncReceiptMismatch.protocolCode?.httpStatus,
        422,
      );
      expect(StorageFailureCode.syncReceiptMismatch.retryable, isFalse);
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
