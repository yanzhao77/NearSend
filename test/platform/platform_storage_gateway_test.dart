import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/platform/platform_storage_gateway.dart';
import 'package:nearsend/platform/storage_location.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(
    MethodChannelAndroidStorageGateway.channelName,
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Android adapter preserves a measured free-space answer', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'measureFreeSpace');
          expect(
            (call.arguments as Map<Object?, Object?>)['locationRef'],
            '/private/received',
          );
          return <String, Object?>{
            'volume': 'android-app-private',
            'label': '应用私有存储',
            'freeBytes': 4096,
          };
        });

    final MethodChannelAndroidStorageGateway gateway =
        MethodChannelAndroidStorageGateway();
    final StorageMeasurement measurement = await gateway.measureFreeSpace(
      location: const StorageLocationRef(
        kind: StorageLocationKind.appPrivate,
        opaqueValue: '/private/received',
        displayName: '应用私有存储',
      ),
    );

    expect(measurement.volume, const VolumeId('android-app-private'));
    expect(measurement.label, '应用私有存储');
    expect(measurement.availability.freeBytes, 4096);
  });

  test(
    'Android adapter does not turn an invalid answer into free space',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            expect(call.method, 'measureFreeSpace');
            return <String, Object?>{
              'volume': 'unknown',
              'label': '保存位置',
              'freeBytes': null,
            };
          });

      final StorageMeasurement measurement =
          await MethodChannelAndroidStorageGateway().measureFreeSpace(
            location: const StorageLocationRef(
              kind: StorageLocationKind.androidDocumentTree,
              opaqueValue: 'content://provider/tree/1',
              displayName: 'Downloads',
            ),
          );

      expect(measurement.availability.freeBytes, isNull);
      expect(measurement.volume, const VolumeId('unknown'));
    },
  );

  test('directory selection returns an opaque structured reference', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'pickReceiveDirectory');
          return <String, Object?>{
            'kind': 'androidDocumentTree',
            'opaqueValue': 'content://provider/tree/1',
            'displayName': 'Downloads',
            'permissionState': 'granted',
          };
        });
    final MethodChannelAndroidStorageGateway gateway =
        MethodChannelAndroidStorageGateway();

    expect(gateway.supportsDirectorySelection, isTrue);
    expect(
      await gateway.pickReceiveDirectory(),
      const StorageLocationRef(
        kind: StorageLocationKind.androidDocumentTree,
        opaqueValue: 'content://provider/tree/1',
        displayName: 'Downloads',
        permissionState: StoragePermissionState.granted,
      ),
    );
  });
}
