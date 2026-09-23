import 'package:flutter/services.dart';

import 'package:nearsend/core/storage/space_plan.dart';

/// A measured answer from a platform storage provider.
class StorageMeasurement {
  const StorageMeasurement({
    required this.volume,
    required this.label,
    required this.availability,
  });

  final VolumeId volume;
  final String label;
  final VolumeAvailability availability;
}

/// Platform boundary for user-selected receive locations and storage facts.
///
/// Implementations deal with SAF URIs, security-scoped URLs and Windows handles. The application
/// layer only receives opaque references and honest measurements; it never turns them into paths or
/// invents free-space values.
abstract interface class PlatformStorageGateway {
  String get platformLabel;

  /// Whether this adapter can return a user-selected directory reference that the export sink
  /// can actually write to. A platform must not expose a picker before its opaque handle is
  /// supported by the write path.
  bool get supportsDirectorySelection => false;

  Future<String?> defaultReceiveLocation();

  Future<String?> pickReceiveDirectory();

  Future<StorageMeasurement> measureFreeSpace({required String? locationRef});
}

/// Default adapter until a platform has a verified native implementation.
class UnknownPlatformStorageGateway implements PlatformStorageGateway {
  const UnknownPlatformStorageGateway({this.platformLabel = '当前平台'});

  @override
  final String platformLabel;

  @override
  bool get supportsDirectorySelection => false;

  @override
  Future<String?> defaultReceiveLocation() async => null;

  @override
  Future<String?> pickReceiveDirectory() async => null;

  @override
  Future<StorageMeasurement> measureFreeSpace({
    required String? locationRef,
  }) async {
    return const StorageMeasurement(
      volume: VolumeId('unknown'),
      label: '保存位置',
      availability: VolumeAvailability.unknown(),
    );
  }
}

/// Android's application storage adapter.
///
/// The native side only returns an app-private path for the default location and a measured
/// `StatFs` answer. Directory selection remains disabled until the Android export sink can write
/// SAF tree URIs; returning a URI to the existing path-only exporter would be an unsafe false
/// capability.
class MethodChannelAndroidStorageGateway implements PlatformStorageGateway {
  MethodChannelAndroidStorageGateway({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'com.nearsend.app/files';

  final MethodChannel _channel;

  @override
  String get platformLabel => 'Android';

  @override
  bool get supportsDirectorySelection => false;

  @override
  Future<String?> defaultReceiveLocation() async {
    final Object? value = await _channel.invokeMethod<Object?>(
      'defaultReceiveLocation',
    );
    return value is String && value.isNotEmpty ? value : null;
  }

  @override
  Future<String?> pickReceiveDirectory() async => null;

  @override
  Future<StorageMeasurement> measureFreeSpace({
    required String? locationRef,
  }) async {
    final Object? value = await _channel.invokeMethod<Object?>(
      'measureFreeSpace',
      <String, Object?>{'locationRef': locationRef},
    );
    if (value is! Map) {
      return const StorageMeasurement(
        volume: VolumeId('unknown'),
        label: '保存位置',
        availability: VolumeAvailability.unknown(),
      );
    }
    final Map<Object?, Object?> result = value.cast<Object?, Object?>();
    final Object? freeBytes = result['freeBytes'];
    final Object? volume = result['volume'];
    final Object? label = result['label'];
    return StorageMeasurement(
      volume: VolumeId(
        volume is String && volume.isNotEmpty ? volume : 'unknown',
      ),
      label: label is String && label.isNotEmpty ? label : '保存位置',
      availability: freeBytes is int && freeBytes >= 0
          ? VolumeAvailability.known(freeBytes)
          : const VolumeAvailability.unknown(),
    );
  }
}
