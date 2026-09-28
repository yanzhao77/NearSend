import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/application/task_catalog_controller.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/features/tasks/presentation/task_overview_page.dart';

void main() {
  testWidgets('clear tasks hides every listed task without deleting records', (
    WidgetTester tester,
  ) async {
    final NearSendDatabase database = NearSendDatabase.open(
      path: NearSendDatabase.inMemoryPath,
    );
    addTearDown(database.close);
    database.db.execute('''
INSERT INTO tasks (
  task_id, role, direction, state, protocol_major, protocol_minor,
  lease_epoch, manifest_digest, created_at, updated_at
) VALUES ('task-visible', 'receiver', 'client_to_server', 'completed', 1, 0, 1, NULL, 1, 2);
''');
    final TaskCatalogController controller = TaskCatalogController()
      ..attach(database);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: TaskOverviewPage(controller: controller)),
    );
    expect(find.text('task-visible'), findsOneWidget);

    await tester.tap(find.text('清空任务'));
    await tester.pump();

    expect(find.text('task-visible'), findsNothing);
    expect(find.text('任务显示已清空'), findsOneWidget);
    expect(controller.tasks, hasLength(1));
    expect(database.db.select('SELECT task_id FROM tasks'), hasLength(1));
  });
}
