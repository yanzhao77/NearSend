import 'package:flutter_test/flutter_test.dart';
import 'package:nearsend/app/application/connection_task_lifecycle.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_schema.dart';
import 'package:nearsend/core/storage/task_credential_repository.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

void main() {
  late NearSendDatabase database;
  late TransferRepository transfers;
  late TaskCredentialRepository credentials;
  setUp(() {
    database = NearSendDatabase.open(path: NearSendDatabase.inMemoryPath);
    transfers = TransferRepository(database);
    credentials = TaskCredentialRepository(database);
  });
  tearDown(() => database.close());

  void task(String id, TransferState state) {
    database.db.execute(
      '''
INSERT INTO tasks (task_id, role, direction, state, protocol_major, protocol_minor,
  lease_epoch, created_at, updated_at)
VALUES (?, 'receiver', 'client_to_server', ?, 1, 0, 1, 1, 1);
''',
      [id, state.name],
    );
    for (final kind in [
      StorageSchema.credentialKindTaskAccess,
      StorageSchema.credentialKindResume,
      StorageSchema.credentialKindCompletionQuery,
    ]) {
      database.db.execute(
        '''
INSERT INTO task_credentials (transfer_id, kind, digest, issued_at, expires_at, consumed_at)
VALUES (?, ?, 'synthetic-digest', 1, NULL, NULL);
''',
        [id, kind],
      );
    }
  }

  List<String> kinds(String id) => [
    for (final row in database.db.select(
      'SELECT kind FROM task_credentials WHERE transfer_id = ? ORDER BY kind;',
      [id],
    ))
      row['kind'] as String,
  ];

  test('disconnect interrupts selected task only and retains durable recovery credentials', () {
    task('selected', TransferState.transferring);
    task('other', TransferState.transferring);
    interruptConnectionTasks(
      taskIds: ['selected'],
      transfers: transfers,
      credentials: credentials,
    );
    expect(transfers.taskState('selected'), TransferState.interrupted);
    expect(transfers.taskState('other'), TransferState.transferring);
    expect(
      kinds('selected'),
      containsAll([
        StorageSchema.credentialKindResume,
        StorageSchema.credentialKindCompletionQuery,
      ]),
    );
    expect(
      kinds('selected'),
      isNot(contains(StorageSchema.credentialKindTaskAccess)),
    );
    expect(kinds('other'), contains(StorageSchema.credentialKindTaskAccess));
  });

  test(
    'proposal without interrupted edge fails instead of waiting forever',
    () {
      task('proposal', TransferState.waitingAccept);
      interruptConnectionTasks(
        taskIds: ['proposal'],
        transfers: transfers,
        credentials: credentials,
      );
      expect(transfers.taskState('proposal'), TransferState.failed);
    },
  );

  test('local verification and export continue without pretending disconnect cancelled saved bytes', () {
    task('verify', TransferState.verifying);
    task('export', TransferState.exporting);
    interruptConnectionTasks(
      taskIds: ['verify', 'export'],
      transfers: transfers,
      credentials: credentials,
    );
    expect(transfers.taskState('verify'), TransferState.verifying);
    expect(transfers.taskState('export'), TransferState.exporting);
    expect(
      kinds('verify'),
      isNot(contains(StorageSchema.credentialKindTaskAccess)),
    );
  });

  test(
    'repeat disconnect is idempotent and preserves completed task records',
    () {
      task('active', TransferState.transferring);
      task('done', TransferState.completed);
      for (int i = 0; i < 2; i++) {
        interruptConnectionTasks(
          taskIds: ['active', 'done'],
          transfers: transfers,
          credentials: credentials,
        );
      }
      expect(transfers.taskState('active'), TransferState.interrupted);
      expect(transfers.taskState('done'), TransferState.completed);
      expect(kinds('done'), hasLength(3));
    },
  );

  test('committed chunk and exported file records survive disconnect', () {
    task('selected', TransferState.transferring);
    database.db.execute('''
INSERT INTO files (file_id, task_id, relative_path, size_bytes, chunk_size_bytes, chunk_count,
 file_sha256, chunk_manifest_digest, export_state, created_at)
VALUES ('file', 'selected', 'sample.bin', 4, 4, 1, 'sha', 'manifest', 'completed', 1);
INSERT INTO chunks (file_id, idx, offset_bytes, length_bytes, sha256, state, committed_at)
VALUES ('file', 0, 0, 4, 'sha', 'committed', 1);
INSERT INTO exports (file_id, target_uri, result, recorded_at)
VALUES ('file', 'synthetic-output', 'saved', 1);
''');
    interruptConnectionTasks(
      taskIds: ['selected'],
      transfers: transfers,
      credentials: credentials,
    );
    expect(
      database.db.select('SELECT state FROM chunks;').single['state'],
      'committed',
    );
    expect(
      database.db.select('SELECT result FROM exports;').single['result'],
      'saved',
    );
  });
}
