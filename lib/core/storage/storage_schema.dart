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
  static const int currentVersion = 9;

  /// The table holding one staging proposal per transfer (§6, ADR-0004).
  static const String manifestStagingTable = 'manifest_staging';

  /// The table holding a staging proposal's file pages, keyed by manifest index.
  static const String manifestFilesTable = 'manifest_files';

  /// The table holding a staging proposal's chunk pages, keyed by file and chunk index.
  static const String manifestChunksTable = 'manifest_chunks';

  /// The column holding the frozen manifest once a proposal is sealed.
  ///
  /// The sealed manifest is what decision, chunk verification and resume read, and §6 says
  /// the window stops applying once it exists. It is stored rather than re-derived so that a
  /// restart can answer those three questions without rebuilding an accumulator, and so that
  /// "the frozen manifest is gone after a restart" stops being true.
  static const String sealedManifestColumn = 'sealed_manifest';

  /// The column holding when a proposal first received content (§6's window start).
  ///
  /// §6 runs the thirty-minute window from the first content rather than from the offer, so
  /// the moment has to survive a restart: a proposal that has been sitting for twenty-nine
  /// minutes must not get a fresh thirty because the process restarted.
  static const String firstContentAtColumn = 'first_content_at';

  /// The table holding one task's issued credentials, by digest only.
  static const String taskCredentialsTable = 'task_credentials';

  /// The table holding what a receiver approved for one task (§6).
  static const String taskAuthorizationsTable = 'task_authorizations';

  /// The table binding a task to the paired peer it belongs to.
  ///
  /// §7 mixes two credential scopes: some rows ask for a "会话身份" and others are "与已授权
  /// 任务绑定". Without this binding a session identity cannot be told apart from one that
  /// merely guessed a transfer id, so the authoriser answered every session on a
  /// transfer-scoped route with `NOT_FOUND` - a capability gap the ledger registered. This
  /// table is what closes it, and it closes it in the fail-closed direction: no row means no
  /// session may reach the task.
  static const String taskAssignmentsTable = 'task_assignments';

  /// The table holding the **sender's mirror** of a client receiver's reported position.
  ///
  /// §9 names the authority explicitly: "服务端发送时响应明确标记 `authority:sender_mirror`，**不能据此
  /// 覆盖客户端本地事实**". So this is a display mirror and nothing else - it is never read to
  /// decide what to send, what to skip or whether a transfer is complete, because
  /// `AGENTS.md` §2 rule 5 makes the receiver's committed rows the only evidence of progress.
  /// Having it as its own table rather than columns on `tasks` is part of that: a reader
  /// looking for progress finds `chunks`, and this table's name says whose numbers these are.
  static const String taskReceiverMirrorTable = 'task_receiver_mirror';

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

  /// Tables schema version 4 adds: the persisted manifest staging of ADR-0004.
  ///
  /// ADR-0004 requires production manifest staging to enter SQLite, and §6 requires a sealed
  /// manifest to remain usable for decision, chunk verification and resume. Three tables
  /// rather than one blob because the rows carry the two orderings §5 and §5.3 fix: a file's
  /// index in the `files` array, and a chunk's index inside its file. Both are primary key
  /// components, so "store by index" - the property that makes a re-sent page unable to
  /// inflate a count - is a property of the schema rather than of a caller.
  ///
  /// `manifest_staging` deliberately has **no** column for the pages themselves and no byte
  /// counter: what a proposal has received is the set of rows in the other two tables.
  static const Map<String, String> version4Tables = <String, String>{
    manifestStagingTable:
        '''
CREATE TABLE manifest_staging (
  transfer_id       TEXT    PRIMARY KEY REFERENCES tasks(task_id) ON DELETE CASCADE,
  manifest_digest   TEXT    NOT NULL,
  protocol_major    INTEGER NOT NULL,
  protocol_minor    INTEGER NOT NULL,
  $firstContentAtColumn INTEGER,
  sealed_at         INTEGER,
  $sealedManifestColumn TEXT,
  seal_result_json  TEXT,
  released_at       INTEGER,
  created_at        INTEGER NOT NULL
);''',

    manifestFilesTable: '''
CREATE TABLE manifest_files (
  transfer_id          TEXT    NOT NULL REFERENCES manifest_staging(transfer_id) ON DELETE CASCADE,
  file_index           INTEGER NOT NULL,
  file_id              TEXT    NOT NULL,
  relative_path        TEXT    NOT NULL,
  size_bytes           INTEGER NOT NULL,
  chunk_size_bytes     INTEGER NOT NULL,
  chunk_count          INTEGER NOT NULL,
  file_sha256          TEXT    NOT NULL,
  chunk_manifest_digest TEXT   NOT NULL,
  PRIMARY KEY (transfer_id, file_index)
);''',

    manifestChunksTable: '''
CREATE TABLE manifest_chunks (
  transfer_id  TEXT    NOT NULL REFERENCES manifest_staging(transfer_id) ON DELETE CASCADE,
  file_id      TEXT    NOT NULL,
  chunk_index  INTEGER NOT NULL,
  length_bytes INTEGER NOT NULL,
  sha256       TEXT    NOT NULL,
  PRIMARY KEY (transfer_id, file_id, chunk_index)
);''',
  };

  /// Indexes schema version 4 adds.
  static const Map<String, String> version4Indexes = <String, String>{
    'manifest_files_by_file': 'CREATE INDEX manifest_files_file ON manifest_files (transfer_id, file_id);',
    'manifest_staging_unsealed':
        'CREATE INDEX manifest_staging_open ON manifest_staging (sealed_at, '
        'first_content_at);',
  };

  /// Tables schema version 5 adds: the durable side of §3's task credentials.
  ///
  /// §2 and `AGENTS.md` §5 keep secrets in platform secure storage, so nothing here holds a
  /// secret: `task_credentials` holds a SHA-256 **digest** of the resume and completion-query
  /// secrets, which is enough to verify a presented secret and useless to an attacker who
  /// reads the file. The task access token is a short-lived bearer, and the same reasoning
  /// applies to it, so it is a digest too.
  ///
  /// `task_authorizations` holds what the receiver approved: the manifest digest it accepted,
  /// the save location it chose and the space estimate it was shown. §6 requires those to be
  /// persisted together with the approval, and "路径或身份变化需要重新确认" needs something to
  /// compare a later request against.
  static const Map<String, String> version5Tables = <String, String>{
    taskCredentialsTable: '''
CREATE TABLE task_credentials (
  transfer_id        TEXT    NOT NULL REFERENCES tasks(task_id) ON DELETE CASCADE,
  kind               TEXT    NOT NULL,
  digest             TEXT    NOT NULL,
  issued_at          INTEGER NOT NULL,
  expires_at         INTEGER,
  consumed_at        INTEGER,
  PRIMARY KEY (transfer_id, kind)
);''',

    taskAuthorizationsTable: '''
CREATE TABLE task_authorizations (
  transfer_id        TEXT    PRIMARY KEY REFERENCES tasks(task_id) ON DELETE CASCADE,
  manifest_digest    TEXT    NOT NULL,
  decision           TEXT    NOT NULL CHECK (decision IN ('accepted', 'rejected')),
  save_location_ref  TEXT,
  space_estimate_json TEXT,
  decided_at         INTEGER NOT NULL,
  receipt_at         INTEGER
);''',

    taskAssignmentsTable: '''
CREATE TABLE task_assignments (
  transfer_id  TEXT    PRIMARY KEY REFERENCES tasks(task_id) ON DELETE CASCADE,
  peer_id      TEXT    NOT NULL,
  assigned_at  INTEGER NOT NULL
);''',

    taskReceiverMirrorTable: '''
CREATE TABLE task_receiver_mirror (
  transfer_id     TEXT    PRIMARY KEY REFERENCES tasks(task_id) ON DELETE CASCADE,
  lease_epoch     INTEGER NOT NULL,
  checkpoint_seq  INTEGER NOT NULL,
  committed_bytes INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);''',
  };

  /// The kinds of credential §3 and §7 define, as stored in [taskCredentialsTable].
  ///
  /// These are database values, not wire values: the wire never names them, and a single
  /// definition here is what keeps a second spelling from appearing at a call site.
  static const String credentialKindResume = 'resume_secret';

  /// The restricted credential §7 gives for a completion query.
  static const String credentialKindCompletionQuery = 'completion_query_secret';

  /// The task access token issued by §7's resume.
  static const String credentialKindTaskAccess = 'task_access_token';

  /// Indexes schema version 5 adds.
  static const Map<String, String> version5Indexes = <String, String>{
    'task_credentials_kind':
        'CREATE INDEX task_credentials_by_kind ON '
        'task_credentials (kind, expires_at);',
  };

  /// The table holding where a sending task reads each file from (§7's chunk `GET`).
  ///
  /// A server that is the sender has to serve chunks from the user's files, and §8 lets a
  /// transfer be resumed after a process restart - so the location has to outlive the process.
  /// It is an **opaque reference**: a full local path is what §7 keeps out of an error body and
  /// `AGENTS.md` §5 keeps out of diagnostics, so what is stored is a handle the platform
  /// adapter resolves.
  static const String taskSourcesTable = 'task_sources';

  /// The table holding non-secret application settings.
  static const String appSettingsTable = 'app_settings';

  /// The receiver's durable local name and destination for every offered file.
  static const String receiveOutputPlansTable = 'receive_output_plans';

  /// Public metadata for the installation identity. Private key bytes never enter this table.
  static const String localIdentityTable = 'local_identity';

  /// Tables schema version 6 adds.
  static const Map<String, String> version6Tables = <String, String>{
    taskSourcesTable: '''
CREATE TABLE task_sources (
  transfer_id  TEXT    NOT NULL REFERENCES tasks(task_id) ON DELETE CASCADE,
  file_id      TEXT    NOT NULL,
  source_ref   TEXT    NOT NULL,
  size_bytes   INTEGER NOT NULL,
  PRIMARY KEY (transfer_id, file_id)
);''',
  };

  /// Indexes schema version 6 adds.
  static const Map<String, String> version6Indexes = <String, String>{};

  /// Tables schema version 7 adds: non-secret application settings.
  static const Map<String, String> version7Tables = <String, String>{
    appSettingsTable: '''
CREATE TABLE app_settings (
  setting_key   TEXT PRIMARY KEY,
  setting_value TEXT NOT NULL,
  updated_at    INTEGER NOT NULL
);''',
  };

  /// Indexes schema version 7 adds.
  static const Map<String, String> version7Indexes = <String, String>{};

  /// Tables schema version 8 adds: local output choices, separate from the signed manifest.
  static const Map<String, String> version8Tables = <String, String>{
    receiveOutputPlansTable: '''
CREATE TABLE receive_output_plans (
  transfer_id       TEXT    NOT NULL,
  file_id           TEXT    NOT NULL,
  original_path     TEXT    NOT NULL,
  selected_name     TEXT    NOT NULL,
  target_ref        TEXT    NOT NULL,
  conflict_policy   TEXT    NOT NULL CHECK (conflict_policy IN ('ask', 'autoRename', 'skip')),
  output_state      TEXT    NOT NULL CHECK (output_state IN ('planned', 'exporting', 'saved', 'failed')),
  final_name        TEXT,
  final_target_ref  TEXT,
  updated_at        INTEGER NOT NULL,
  PRIMARY KEY (transfer_id, file_id)
);''',
  };

  static const Map<String, String> version8Indexes = <String, String>{
    'receive_outputs_by_transfer': 'CREATE INDEX receive_outputs_transfer ON receive_output_plans (transfer_id);',
  };

  static const Map<String, String> version9Tables = <String, String>{
    localIdentityTable: '''
CREATE TABLE local_identity (
  id             INTEGER PRIMARY KEY CHECK (id = 1),
  device_id      TEXT    NOT NULL,
  public_key     TEXT    NOT NULL,
  key_reference  TEXT    NOT NULL,
  format_version INTEGER NOT NULL,
  created_at     INTEGER NOT NULL
);''',
  };

  static const Map<String, String> version9Indexes = <String, String>{
    'peers_by_last_seen':
        'CREATE INDEX peers_last_seen ON peers (last_seen_at DESC);',
  };

  /// The indexes this schema version defines.
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

  /// Applies schema version 4 to [db]: persists manifest staging (ADR-0004).
  ///
  /// New tables only, so no existing row is rewritten. A transfer that was mid-proposal when
  /// the upgrade happened simply has no staging row: the client re-uploads its pages, which
  /// §6 makes safe ("重传相同页返回成功"), and this build must not claim to have recovered
  /// staging it never stored.
  static void applyVersion4(Database db) {
    for (final String ddl in version4Tables.values) {
      db.execute(ddl);
    }
    for (final String ddl in version4Indexes.values) {
      db.execute(ddl);
    }
  }

  /// Applies schema version 5 to [db]: task credentials and authorisation records.
  ///
  /// New tables only, so no existing row is rewritten. A task created before this version has
  /// no authorisation record, which is honest: nothing approved it under the new shape.
  static void applyVersion5(Database db) {
    for (final String ddl in version5Tables.values) {
      db.execute(ddl);
    }
    for (final String ddl in version5Indexes.values) {
      db.execute(ddl);
    }
  }

  /// Applies schema version 6 to [db]: where a sending task reads each file from.
  ///
  /// New table only. A task that existed before this version has no recorded source, so a
  /// chunk `GET` for it cannot be served - which is the correct answer rather than reading
  /// from a guessed location.
  static void applyVersion6(Database db) {
    for (final String ddl in version6Tables.values) {
      db.execute(ddl);
    }
    for (final String ddl in version6Indexes.values) {
      db.execute(ddl);
    }
  }

  /// Applies schema version 7 to [db]: adds non-secret application settings.
  static void applyVersion7(Database db) {
    for (final String ddl in version7Tables.values) {
      db.execute(ddl);
    }
    for (final String ddl in version7Indexes.values) {
      db.execute(ddl);
    }
  }

  /// Applies schema version 8 without rewriting manifests or existing task rows.
  static void applyVersion8(Database db) {
    for (final String ddl in version8Tables.values) {
      db.execute(ddl);
    }
    for (final String ddl in version8Indexes.values) {
      db.execute(ddl);
    }
  }

  /// Applies schema version 9: stable local identity metadata and richer peer history.
  static void applyVersion9(Database db) {
    for (final String ddl in version9Tables.values) {
      db.execute(ddl);
    }
    db.execute('ALTER TABLE peers ADD COLUMN identity_public_key TEXT;');
    db.execute('ALTER TABLE peers ADD COLUMN platform TEXT;');
    db.execute(
      "ALTER TABLE peers ADD COLUMN trust_state TEXT NOT NULL DEFAULT 'unknown' "
      "CHECK (trust_state IN ('unknown', 'authorized', 'revoked'));",
    );
    db.execute('ALTER TABLE peers ADD COLUMN paired_at INTEGER;');
    db.execute('ALTER TABLE peers ADD COLUMN last_verified_at INTEGER;');
    db.execute(
      "UPDATE peers SET trust_state = CASE WHEN authorized = 1 "
      "THEN 'authorized' ELSE 'revoked' END, paired_at = last_seen_at, "
      'last_verified_at = CASE WHEN authorized = 1 THEN last_seen_at ELSE NULL END;',
    );
    for (final String ddl in version9Indexes.values) {
      db.execute(ddl);
    }
  }

  /// The names of every table in this schema version, including the metadata table.
  static Set<String> get tableNames => <String>{
    metaTable,
    ...tables.keys,
    ...version4Tables.keys,
    ...version5Tables.keys,
    ...version6Tables.keys,
    ...version7Tables.keys,
    ...version8Tables.keys,
    ...version9Tables.keys,
  };
}
