import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/application/task_catalog_controller.dart';
import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/features/tasks/presentation/task_detail_page.dart';
import 'package:nearsend/platform/platform_file_actions.dart';

void main() {
  NearSendDatabase databaseFor(String state) {
    final NearSendDatabase database = NearSendDatabase.open(
      path: NearSendDatabase.inMemoryPath,
    );
    database.db.execute('''
INSERT INTO tasks (
  task_id, role, direction, state, protocol_major, protocol_minor,
  lease_epoch, manifest_digest, created_at, updated_at
) VALUES ('task-ui', 'receiver', 'client_to_server', '$state', 1, 0, 1, NULL, 1, 2);
''');
    database.db.execute('''
INSERT INTO files (
  file_id, task_id, relative_path, size_bytes, chunk_size_bytes, chunk_count,
  file_sha256, chunk_manifest_digest, export_state, created_at
) VALUES ('file-ui', 'task-ui', 'a-very-long-file-name.txt', 4, 4, 1, 'sha', 'manifest', 'completed', 1);
''');
    database.db.execute('''
INSERT INTO chunks (file_id, idx, offset_bytes, length_bytes, sha256, state, committed_at)
VALUES ('file-ui', 0, 0, 4, 'a', 'committed', 2);
''');
    database.db.execute('''
INSERT INTO exports (file_id, target_uri, result, recorded_at, saved_path)
VALUES ('file-ui', 'opaque://documents', 'saved', 3, 'a-very-long-file-name.txt');
''');
    database.db.execute('''
INSERT INTO receive_output_plans (
  transfer_id, file_id, original_path, selected_name, target_ref,
  conflict_policy, output_state, final_name, final_target_ref, updated_at
) VALUES (
  'task-ui', 'file-ui', 'a-very-long-file-name.txt',
  'a-very-long-file-name.txt', 'opaque://documents', 'autoRename', 'saved',
  'a-very-long-file-name.txt', 'content://documents/file-ui', 3
);
''');
    return database;
  }

  testWidgets('completed task uses real saved state and no fake retry action', (
    tester,
  ) async {
    final NearSendDatabase database = databaseFor('completed');
    addTearDown(database.close);
    final TaskCatalogController controller = TaskCatalogController()
      ..attach(database);
    final _RecordingFileActions actions = _RecordingFileActions();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildNearSendTheme(Brightness.light),
        home: TaskDetailPage(
          controller: controller,
          taskId: 'task-ui',
          fileActions: actions,
        ),
      ),
    );

    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('已校验并保存'), findsWidgets);
    expect(find.text('重试'), findsNothing);
    expect(find.text('a-very-long-file-name.txt'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '打开'));
    await tester.pump();
    expect(actions.opened, <String>['content://documents/file-ui']);
    final Finder reveal = find.widgetWithText(TextButton, '显示位置');
    await tester.ensureVisible(reveal);
    await tester.pump();
    await tester.tap(reveal);
    await tester.pump();
    expect(actions.revealed, <String>['content://documents/file-ui']);
  });

  testWidgets('paused task exposes continue only when capability is supplied', (
    tester,
  ) async {
    final NearSendDatabase database = databaseFor('paused');
    addTearDown(database.close);
    final TaskCatalogController controller = TaskCatalogController()
      ..attach(database);
    int resumes = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildNearSendTheme(Brightness.light),
        home: TaskDetailPage(
          controller: controller,
          taskId: 'task-ui',
          onResume: () => resumes++,
        ),
      ),
    );

    expect(find.text('继续'), findsOneWidget);
    await tester.tap(find.text('继续'));
    expect(resumes, 1);
    expect(find.textContaining('恢复前会先检查本地已接收内容'), findsOneWidget);
  });
}

class _RecordingFileActions implements PlatformFileActions {
  final List<String> opened = <String>[];
  final List<String> revealed = <String>[];

  @override
  bool get supportsOpen => true;

  @override
  bool get supportsReveal => true;

  @override
  Future<PlatformFileActionResult> open(String targetRef) async {
    opened.add(targetRef);
    return const PlatformFileActionResult(PlatformFileActionStatus.completed);
  }

  @override
  Future<PlatformFileActionResult> reveal(String targetRef) async {
    revealed.add(targetRef);
    return const PlatformFileActionResult(PlatformFileActionStatus.completed);
  }
}
