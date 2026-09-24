import 'package:flutter/services.dart';

enum PlatformPermissionKind { camera, files }

enum PlatformPermissionState {
  notDetermined,
  granted,
  denied,
  scopedSystemPicker,
  unavailable;

  bool get allowsUse =>
      this == PlatformPermissionState.granted ||
      this == PlatformPermissionState.scopedSystemPicker;
}

abstract interface class PlatformPermissionGateway {
  Future<PlatformPermissionState> check(PlatformPermissionKind permission);

  Future<PlatformPermissionState> request(PlatformPermissionKind permission);
}

/// Checks access immediately before a protected platform operation.
///
/// File and directory pickers are themselves the permission request on SAF,
/// UIDocumentPicker and the Windows file dialog. They must not be replaced by a
/// broad storage permission such as MANAGE_EXTERNAL_STORAGE.
Future<PlatformPermissionState> ensurePlatformPermission(
  PlatformPermissionGateway gateway,
  PlatformPermissionKind permission,
) async {
  final PlatformPermissionState current = await gateway.check(permission);
  if (current.allowsUse || current == PlatformPermissionState.unavailable) {
    return current;
  }
  return gateway.request(permission);
}

class MethodChannelPlatformPermissionGateway
    implements PlatformPermissionGateway {
  const MethodChannelPlatformPermissionGateway({
    this.cameraChannel = const MethodChannel(cameraChannelName),
  });

  static const String cameraChannelName =
      'dev.steenbakker.mobile_scanner/scanner/method';

  final MethodChannel cameraChannel;

  @override
  Future<PlatformPermissionState> check(
    PlatformPermissionKind permission,
  ) async {
    if (permission == PlatformPermissionKind.files) {
      return PlatformPermissionState.scopedSystemPicker;
    }
    try {
      final int raw = await cameraChannel.invokeMethod<int>('state') ?? 0;
      return switch (raw) {
        0 => PlatformPermissionState.notDetermined,
        1 => PlatformPermissionState.granted,
        _ => PlatformPermissionState.denied,
      };
    } on MissingPluginException {
      return PlatformPermissionState.unavailable;
    } on PlatformException {
      return PlatformPermissionState.unavailable;
    }
  }

  @override
  Future<PlatformPermissionState> request(
    PlatformPermissionKind permission,
  ) async {
    if (permission == PlatformPermissionKind.files) {
      return PlatformPermissionState.scopedSystemPicker;
    }
    try {
      final bool granted =
          await cameraChannel.invokeMethod<bool>('request') ?? false;
      return granted
          ? PlatformPermissionState.granted
          : PlatformPermissionState.denied;
    } on MissingPluginException {
      return PlatformPermissionState.unavailable;
    } on PlatformException {
      return PlatformPermissionState.unavailable;
    }
  }
}
