import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/platform/device_info_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('maps supported operating systems to stable ids and display names', () {
    for (final (TargetPlatform target, String id, String label)
        in <(TargetPlatform, String, String)>[
          (TargetPlatform.android, 'android', 'Android'),
          (TargetPlatform.iOS, 'ios', 'iOS'),
          (TargetPlatform.windows, 'windows', 'Windows'),
          (TargetPlatform.macOS, 'macos', 'macOS'),
          (TargetPlatform.linux, 'linux', 'Linux'),
        ]) {
      expect(platformIdFor(target), id);
      expect(platformLabelForId(id), label);
    }
  });

  test(
    'reads Android configured device name through the platform adapter',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const MethodChannel channel = MethodChannel(
        'com.nearsend.app/device_info',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            expect(call.method, 'readDeviceName');
            return 'Pixel 家庭机';
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      });

      final LocalDeviceInfo info = await const MethodChannelDeviceInfoGateway(
        channel: channel,
      ).read();

      expect(info.name, 'Pixel 家庭机');
      expect(info.platformId, 'android');
      expect(info.platformLabel, 'Android');
    },
  );
}
