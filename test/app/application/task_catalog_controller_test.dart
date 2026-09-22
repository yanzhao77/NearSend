import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/application/task_catalog_controller.dart';
import 'package:nearsend/core/storage/near_send_database.dart';

void main() {
  test('reads task progress from committed chunks only', () {
    final NearSendDatabase database = NearSendDatabase.open(
      path: NearSendDatabase.inMemoryPath,
    );
    addTearDown(database.close);
    database.db.execute('''
INSERT INTO tasks (
  task_id, role, direction, state, protocol_major, protocol_minor,
  lease_epoch, manifest_digest, created_at, updated_at
) VALUES ('task-1', 'receiver', 'client_to_server', 'transferring', 1, 0, 1, NULL, 1, 2);
''');
    database.db.execute('''
INSERT INTO files (
  file_id, task_id, relative_path, size_bytes, chunk_size_bytes, chunk_count,
  file_sha256, chunk_manifest_digest, export_state, created_at
) VALUES ('file-1', 'task-1', 'report.txt', 12, 4, 3, 'sha', 'manifest', 'transferring', 1);
''');
    database.db.execute('''
INSERT INTO chunks (file_id, idx, offset_bytes, length_bytes, sha256, state, committed_at)
VALUES ('file-1', 0, 0, 4, 'a', 'committed', 2);
''');
    database.db.execute('''
INSERT INTO chunks (file_id, idx, offset_bytes, length_bytes, sha256, state, committed_at)
VALUES ('file-1', 1, 4, 4, 'b', 'missing', NULL);
''');
    database.db.execute('''
INSERT INTO chunks (file_id, idx, offset_bytes, length_bytes, sha256, state, committed_at)
VALUES ('file-1', 2, 8, 4, 'c', 'committed', 2);
''');

    final TaskCatalogController controller = TaskCatalogController()
      ..attach(database);
    expect(controller.tasks, hasLength(1));
    expect(controller.tasks.single.totalBytes, 12);
    expect(controller.tasks.single.committedBytes, 8);
    expect(controller.tasks.single.progress, closeTo(2 / 3, 0.001));
    expect(controller.tasks.single.status, TaskOverviewStatus.active);
  });
}
