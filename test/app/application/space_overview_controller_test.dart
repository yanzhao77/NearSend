import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/application/space_overview_controller.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/platform/platform_storage_gateway.dart';

void main() {
  test('unknown platform space remains unknown', () async {
    final SpaceOverviewController controller = SpaceOverviewController();
    await controller.refresh();

    expect(controller.overview.hasUnknown, isTrue);
    expect(controller.overview.volumes.single.verdict, SpaceVerdict.unknown);
  });

  test(
    'known measurement is exposed without inventing a required amount',
    () async {
      final SpaceOverviewController controller = SpaceOverviewController(
        gateway: _FakeStorageGateway(
          measurement: const StorageMeasurement(
            volume: VolumeId('disk-1'),
            label: '主磁盘',
            availability: VolumeAvailability.known(1024),
          ),
        ),
      );
      await controller.refresh();

      expect(controller.overview.volumes.single.label, '主磁盘');
      expect(controller.overview.volumes.single.availability.freeBytes, 1024);
      expect(controller.overview.volumes.single.verdict, SpaceVerdict.unknown);
    },
  );
}

class _FakeStorageGateway implements PlatformStorageGateway {
  const _FakeStorageGateway({required this.measurement});

  final StorageMeasurement measurement;

  @override
  String get platformLabel => 'test';

  @override
  Future<String?> defaultReceiveLocation() async => 'opaque://location';

  @override
  Future<String?> pickReceiveDirectory() async => 'opaque://picked';

  @override
  Future<StorageMeasurement> measureFreeSpace({
    required String? locationRef,
  }) async => measurement;
}
