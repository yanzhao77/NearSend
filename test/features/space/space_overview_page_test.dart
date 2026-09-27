import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/application/space_overview_controller.dart';
import 'package:nearsend/app/application/task_catalog_controller.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/features/space/presentation/space_overview_page.dart';
import 'package:nearsend/platform/platform_storage_gateway.dart';
import 'package:nearsend/platform/storage_location.dart';

void main() {
  testWidgets(
    'idle page shows measured capacity without claiming sufficiency',
    (WidgetTester tester) async {
      final SpaceOverviewController controller = SpaceOverviewController(
        gateway: _FakeStorageGateway(
          const StorageMeasurement(
            volume: VolumeId('disk-1'),
            label: '主磁盘',
            availability: VolumeAvailability.known(3 * 1024 * 1024 * 1024),
          ),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(home: SpaceOverviewPage(controller: controller)),
      );
      await tester.pumpAndSettle();

      expect(find.text('空间未知'), findsNothing);
      expect(find.text('容量已读取'), findsOneWidget);
      expect(find.text('无待接收文件'), findsOneWidget);
      expect(find.text('3.0 GiB'), findsOneWidget);
      expect(find.text('空间充足'), findsNothing);
      controller.dispose();
    },
  );

  testWidgets('lists verified received files with their saved destination', (
    WidgetTester tester,
  ) async {
    final NearSendDatabase database = NearSendDatabase.open(
      path: NearSendDatabase.inMemoryPath,
    );
    addTearDown(database.close);
    final TaskCatalogController tasks = TaskCatalogController()
      ..attach(database);
    addTearDown(tasks.dispose);
    database.db.execute('''
INSERT INTO tasks (
  task_id, role, direction, state, protocol_major, protocol_minor,
  lease_epoch, manifest_digest, created_at, updated_at
) VALUES ('received-task', 'receiver', 'client_to_server', 'completed', 1, 0, 1, NULL, 1, 2);
''');
    database.db.execute('''
INSERT INTO files (
  file_id, task_id, relative_path, size_bytes, chunk_size_bytes, chunk_count,
  file_sha256, chunk_manifest_digest, export_state, created_at
) VALUES ('received-file', 'received-task', 'report.txt', 4, 4, 1, 'sha', 'manifest', 'completed', 1);
''');
    database.db.execute('''
INSERT INTO exports (file_id, target_uri, result, recorded_at, saved_path)
VALUES ('received-file', 'C:/Users/test/Downloads', 'saved', 3, 'report.txt');
''');
    tasks.refresh();
    final SpaceOverviewController controller = SpaceOverviewController(
      gateway: _FakeStorageGateway(
        const StorageMeasurement(
          volume: VolumeId('disk-1'),
          label: '主磁盘',
          availability: VolumeAvailability.known(1024),
        ),
      ),
      tasks: tasks,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: SpaceOverviewPage(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text('已接收文件'), findsOneWidget);
    expect(find.text('report.txt'), findsOneWidget);
    expect(
      find.text('保存位置：C:/Users/test/Downloads/report.txt'),
      findsOneWidget,
    );
    expect(find.text('4 B'), findsOneWidget);
  });
}

class _FakeStorageGateway implements PlatformStorageGateway {
  const _FakeStorageGateway(this.measurement);

  final StorageMeasurement measurement;

  @override
  String get platformLabel => 'test';

  @override
  bool get supportsDirectorySelection => false;

  @override
  Future<StorageLocationRef?> defaultReceiveLocation() async =>
      const StorageLocationRef(
        kind: StorageLocationKind.nativeDirectory,
        opaqueValue: '/location',
        displayName: 'location',
      );

  @override
  Future<StorageLocationRef?> pickReceiveDirectory() async => null;

  @override
  Future<StorageLocationRef> validateReceiveLocation(
    StorageLocationRef location,
  ) async => location;

  @override
  Future<StorageMeasurement> measureFreeSpace({
    required StorageLocationRef? location,
  }) async => measurement;
}
