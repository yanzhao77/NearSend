import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/platform/platform_storage_gateway.dart';
import 'package:nearsend/platform/storage_location.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(
    MethodChannelWindowsStorageGateway.channelName,
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Windows picker returns a native directory reference', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'pickReceiveDirectory');
          return <String, Object?>{
            'kind': 'nativeDirectory',
            'opaqueValue': r'C:\Users\User\Downloads',
            'displayName': 'Downloads',
            'permissionState': 'granted',
          };
        });

    final StorageLocationRef? location =
        await MethodChannelWindowsStorageGateway().pickReceiveDirectory();
    expect(location?.kind, StorageLocationKind.nativeDirectory);
    expect(location?.displayName, 'Downloads');
    expect(location?.permissionState, StoragePermissionState.granted);
  });

  test('Windows adapter preserves unavailable validation', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'validateReceiveDirectory');
          return <String, Object?>{
            'kind': 'nativeDirectory',
            'opaqueValue': r'E:\Removed',
            'displayName': 'Removed',
            'permissionState': 'unavailable',
          };
        });

    final StorageLocationRef result = await MethodChannelWindowsStorageGateway()
        .validateReceiveLocation(
          const StorageLocationRef(
            kind: StorageLocationKind.nativeDirectory,
            opaqueValue: r'E:\Removed',
            displayName: 'Removed',
          ),
        );
    expect(result.permissionState, StoragePermissionState.unavailable);
  });

  test('Windows free-space failure remains unknown', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'measureFreeSpace');
          return <String, Object?>{
            'volume': 'unknown',
            'label': 'Windows storage',
            'freeBytes': null,
          };
        });

    final StorageMeasurement result = await MethodChannelWindowsStorageGateway()
        .measureFreeSpace(
          location: const StorageLocationRef(
            kind: StorageLocationKind.nativeDirectory,
            opaqueValue: r'E:\Removed',
            displayName: 'Removed',
          ),
        );
    expect(result.volume, const VolumeId('unknown'));
    expect(result.availability.freeBytes, isNull);
  });
}
