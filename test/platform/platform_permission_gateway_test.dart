import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/platform/platform_permission_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('test.nearsend/permissions');
  final List<String> calls = <String>[];

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    calls.clear();
  });

  test('an existing camera grant is checked without another request', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call.method);
          return switch (call.method) {
            'state' => 1,
            'request' => true,
            _ => null,
          };
        });
    const MethodChannelPlatformPermissionGateway gateway =
        MethodChannelPlatformPermissionGateway(cameraChannel: channel);

    expect(
      await ensurePlatformPermission(gateway, PlatformPermissionKind.camera),
      PlatformPermissionState.granted,
    );
    expect(calls, <String>['state']);
  });

  test('missing camera access is requested and denial is preserved', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call.method);
          return switch (call.method) {
            'state' => 0,
            'request' => false,
            _ => null,
          };
        });
    const MethodChannelPlatformPermissionGateway gateway =
        MethodChannelPlatformPermissionGateway(cameraChannel: channel);

    expect(
      await ensurePlatformPermission(gateway, PlatformPermissionKind.camera),
      PlatformPermissionState.denied,
    );
    expect(calls, <String>['state', 'request']);
  });

  test('file access is delegated to the scoped system picker', () async {
    const MethodChannelPlatformPermissionGateway gateway =
        MethodChannelPlatformPermissionGateway(cameraChannel: channel);

    expect(
      await ensurePlatformPermission(gateway, PlatformPermissionKind.files),
      PlatformPermissionState.scopedSystemPicker,
    );
    expect(calls, isEmpty);
  });
}
