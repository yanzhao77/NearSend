import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/application/space_overview_controller.dart';
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
