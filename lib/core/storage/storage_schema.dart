/// The receiver's SQLite schema, `docs/architecture/SYSTEM_ARCHITECTURE.md` §8.
///
/// ## Why the schema is written out rather than generated
///
/// The tables encode the project's core storage guarantees, and each one is deliberate:
///
/// * `chunks` is the **sole authority** for resumable progress. `AGENTS.md` §2 rule 5
///   forbids deriving recovery from a byte counter, so there is deliberately no
///   `received_bytes` or `written_bytes` column that a recovery path could reach for.
/// * `chunks.state` distinguishes an uncommitted block from a committed one, because a
///   block that was written but not durably committed must be re-sent rather than
///   trusted.
/// * `idempotency` is keyed by task, operation and credential fingerprint, matching the
///   scope from protocol §9, so a request id from before a re-pairing cannot collide
///   with one after it.
/// * `tasks.lease_epoch` is the write generation; a commit that does not present the
///   current generation is refused.
///
/// Nothing here stores recovery secrets, keys or tokens: `AGENTS.md` §5 keeps those in
/// platform secure storage. The schema keeps only a credential *fingerprint*.
library;

import 'package:sqlite3/sqlite3.dart';

/// The schema definition and its version.
abstract final class StorageSchema {
  /// The version this build writes and understands.
  ///
  /// Monotonic. A database whose stored version is **higher** than this is refused
  /// rather than migrated downwards, because a newer build may have written structures
  /// this one would corrupt by ignoring.
  static const int currentVersion = 3;

  /// The column version 3 adds to `tasks`, holding the last committed checkpoint (§8).
  ///
  /// §8 commits "块标志和 checkpointSeq" in one transaction, and §9 has the receiver report
  /// `{leaseEpoch, checkpointSeq, committedBytes}` and the sender verify it does not
  /// regress. A counter that only lived in memory would restart at zero and look like a
  /// regression, so it is persisted.
  ///
  /// It lives on `tasks` rather than `files` because its partner `lease_epoch` - the value
  /// it is always reported and compared with - is a task-scoped write generation. Scope is
  /// registered as a decision to confirm in the ledger, since §8 does not name the scope.
  static const String tasksCheckpointSeqColumn = 'checkpoint_seq';

  /// The column version 2 adds to `exports`, holding the name the copy was written under.
  ///
  /// A saved export without a name cannot answer "where is my file", and a retry cannot
  /// tell whether it is looking at its own earlier write. The frozen `relativePath` is
  /// not a substitute: the copy may have been renamed to avoid overwriting something the
  /// user already had.
  static const String exportsSavedPathColumn = 'saved_path';

  /// The table holding the single row of schema metadata.
  static const String metaTable = 'schema_info';

  /// Statement that creates the metadata table, which must exist before versioning.
  static const String createMetaTable =
      '''
CREATE TABLE IF NOT EXISTS $metaTable (
  id         INTEGER PRIMARY KEY CHECK (id = 1),
  version    INTEGER NOT NULL,
  applied_at INTEGER NOT NULL
);''';

  /// Every table this schema version defines, in creation order.
  ///
  /// Exposed as data so tests can assert the set of tables without duplicating SQL.
  static const Map<String, String> tables = <String, String>{
    'tasks': '''
CREATE TABLE tasks (
  task_id          TEXT    PRIMARY KEY,
  role             TEXT    NOT NULL,
  direction        TEXT    NOT NULL,
  state            TEXT    NOT NULL,
  protocol_major   INTEGER NOT NULL,
  protocol_minor   INTEGER NOT NULL,
  lease_epoch      INTEGER NOT NULL DEFAULT 0,
  manifest_digest  TEXT,
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL
);''',

    'files': '''
CREATE TABLE files (
  file_id                TEXT    PRIMARY KEY,
  task_id                TEXT    NOT NULL REFERENCES tasks(task_id) ON DELETE CASCADE,
  relative_path          TEXT    NOT NULL,
  size_bytes             INTEGER NOT NULL,
  chunk_size_bytes       INTEGER NOT NULL,
  chunk_count            INTEGER NOT NULL,
  file_sha256            TEXT    NOT NULL,
  chunk_manifest_digest  TEXT    NOT NULL,
  export_state           TEXT    NOT NULL,
  created_at             INTEGER NOT NULL
);''',

    // The authority table. `state` is missing/committed only; there is no third
    // "written" state, because "written but not synced" is not progress.
    'chunks': '''
CREATE TABLE chunks (
  file_id       TEXT    NOT NULL REFERENCES files(file_id) ON DELETE CASCADE,
  idx           INTEGER NOT NULL,
  offset_bytes  INTEGER NOT NULL,
  length_bytes  INTEGER NOT NULL,
  sha256        TEXT    NOT NULL,
  state         TEXT    NOT NULL CHECK (state IN ('missing', 'committed')),
  committed_at  INTEGER,
  PRIMARY KEY (file_id, idx)
);''',

    'peers': '''
CREATE TABLE peers (
  peer_id              TEXT PRIMARY KEY,
  display_name         TEXT,
  identity_fingerprint TEXT NOT NULL,
  authorized           INTEGER NOT NULL DEFAULT 0,
  last_seen_at         INTEGER
);''',

    'idempotency': '''
CREATE TABLE idempotency (
  transfer_id            TEXT    NOT NULL,
  operation              TEXT    NOT NULL,
  credential_fingerprint TEXT    NOT NULL,
  request_id             TEXT    NOT NULL,
  request_digest         TEXT    NOT NULL,
  state                  TEXT    NOT NULL CHECK (state IN ('in_flight', 'completed')),
  lease_epoch            INTEGER NOT NULL,
  result_json            TEXT,
  created_at             INTEGER NOT NULL,
  expires_at             INTEGER,
  PRIMARY KEY (transfer_id, operation, credential_fingerprint, request_id)
);''',

    'exports': '''
CREATE TABLE exports (
  file_id       TEXT    PRIMARY KEY REFERENCES files(file_id) ON DELETE CASCADE,
  target_uri    TEXT    NOT NULL,
  result        TEXT    NOT NULL,
  recorded_at   INTEGER NOT NULL
);''',
  };

  /// Indexes this schema version defines.
  static const Map<String, String> indexes = <String, String>{
    'chunks_missing':
        'CREATE INDEX chunks_file_state ON chunks (file_id, state);',
    'files_by_task': 'CREATE INDEX files_task ON files (task_id);',
    'idempotency_expiry':
        'CREATE INDEX idempotency_expires ON idempotency (expires_at);',
  };

  /// Applies schema version 1 to [db].
  ///
  /// Called only by the migration framework, inside a transaction it controls, so that
  /// a failure part way through leaves the database untouched.
  ///
  /// **Never edit this for a later version.** A database in the field already ran it, so
  /// changing it would make a fresh database and an upgraded one differ in ways no test
  /// would notice until the difference mattered.
  static void applyVersion1(Database db) {
    db.execute(createMetaTable);
    for (final String ddl in tables.values) {
      db.execute(ddl);
    }
    for (final String ddl in indexes.values) {
      db.execute(ddl);
    }
  }

  /// Applies schema version 2 to [db]: remembers the name a saved export used.
  ///
  /// `ALTER TABLE ... ADD COLUMN` is used rather than a table rebuild because it is
  /// transactional in SQLite and preserves every existing row. Rows written by version 1
  /// keep a null name, which is the honest answer: that build genuinely did not record
  /// one, and inventing the frozen path would claim the copy was saved under a name it
  /// may never have been given.
  static void applyVersion2(Database db) {
    db.execute('ALTER TABLE exports ADD COLUMN $exportsSavedPathColumn TEXT;');
  }

  /// Applies schema version 3 to [db]: remembers the last committed checkpoint (§8).
  ///
  /// `ALTER TABLE ... ADD COLUMN ... NOT NULL DEFAULT 0` rather than a table rebuild: it is
  /// transactional in SQLite and keeps every existing row. An existing task legitimately
  /// has no committed checkpoint yet under the new counter, and 0 is what "no checkpoint
  /// has been taken" means - not a fabricated sequence number.
  static void applyVersion3(Database db) {
    db.execute(
      'ALTER TABLE tasks ADD COLUMN $tasksCheckpointSeqColumn INTEGER NOT NULL '
      'DEFAULT 0;',
    );
  }

  /// The names of every table in this schema version, including the metadata table.
  static Set<String> get tableNames => <String>{metaTable, ...tables.keys};
}
