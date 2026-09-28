import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Display-only facts about this installation. They never take part in pairing identity.
class LocalDeviceInfo {
  const LocalDeviceInfo({required this.name, required this.platformId});

  final String name;
  final String platformId;

  String get platformLabel => platformLabelForId(platformId);
}

abstract interface class DeviceInfoGateway {
  Future<LocalDeviceInfo> read();
}

class MethodChannelDeviceInfoGateway implements DeviceInfoGateway {
  const MethodChannelDeviceInfoGateway({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.nearsend.app/device_info');

  final MethodChannel _channel;

  @override
  Future<LocalDeviceInfo> read() async {
    final TargetPlatform target = defaultTargetPlatform;
    final String platformId = platformIdFor(target);
    String? name;
    if (target == TargetPlatform.android) {
      try {
        name = await _channel.invokeMethod<String>('readDeviceName');
      } on MissingPluginException {
        // Tests and older host builds fall back to the runtime hostname below.
      } on PlatformException {
        // A system setting may be unavailable; a model/hostname fallback is still useful.
      }
    }
    if (name == null || name.trim().isEmpty) {
      name = Platform.localHostname;
    }
    final String normalized = name.trim();
    return LocalDeviceInfo(
      name: normalized.isEmpty ? defaultDeviceNameFor(target) : normalized,
      platformId: platformId,
    );
  }
}

String platformIdFor(TargetPlatform target) => switch (target) {
  TargetPlatform.android => 'android',
  TargetPlatform.iOS => 'ios',
  TargetPlatform.windows => 'windows',
  TargetPlatform.macOS => 'macos',
  TargetPlatform.linux => 'linux',
  TargetPlatform.fuchsia => 'fuchsia',
};

String platformLabelForId(String platformId) =>
    switch (platformId.toLowerCase()) {
      'android' => 'Android',
      'ios' => 'iOS',
      'windows' => 'Windows',
      'macos' || 'mac' => 'macOS',
      'linux' => 'Linux',
      'fuchsia' => 'Fuchsia',
      _ => '平台未知',
    };

String defaultDeviceNameFor(TargetPlatform target) => switch (target) {
  TargetPlatform.android => 'Android设备',
  TargetPlatform.iOS => 'iPhone或iPad',
  TargetPlatform.windows => 'Windows设备',
  TargetPlatform.macOS => 'Mac',
  TargetPlatform.linux => 'Linux设备',
  TargetPlatform.fuchsia => 'Fuchsia设备',
};
