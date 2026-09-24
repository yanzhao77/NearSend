import 'package:flutter/services.dart';

import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/platform/storage_location.dart';

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

  Future<StorageLocationRef?> defaultReceiveLocation();

  Future<StorageLocationRef?> pickReceiveDirectory();

  Future<StorageLocationRef> validateReceiveLocation(
    StorageLocationRef location,
  );

  Future<StorageMeasurement> measureFreeSpace({
    required StorageLocationRef? location,
  });
}

/// Default adapter until a platform has a verified native implementation.
class UnknownPlatformStorageGateway implements PlatformStorageGateway {
  const UnknownPlatformStorageGateway({this.platformLabel = '当前平台'});

  @override
  final String platformLabel;

  @override
  bool get supportsDirectorySelection => false;

  @override
  Future<StorageLocationRef?> defaultReceiveLocation() async => null;

  @override
  Future<StorageLocationRef?> pickReceiveDirectory() async => null;

  @override
  Future<StorageLocationRef> validateReceiveLocation(
    StorageLocationRef location,
  ) async => location.withPermissionState(StoragePermissionState.unavailable);

  @override
  Future<StorageMeasurement> measureFreeSpace({
    required StorageLocationRef? location,
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
/// The native side owns SAF tree parsing and permission checks. Dart only carries the opaque URI.
class MethodChannelAndroidStorageGateway implements PlatformStorageGateway {
  MethodChannelAndroidStorageGateway({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'com.nearsend.app/files';

  final MethodChannel _channel;

  @override
  String get platformLabel => 'Android';

  @override
  bool get supportsDirectorySelection => true;

  @override
  Future<StorageLocationRef?> defaultReceiveLocation() async {
    final Object? value = await _channel.invokeMethod<Object?>(
      'defaultReceiveLocation',
    );
    return value == null ? null : StorageLocationRef.fromPlatformValue(value);
  }

  @override
  Future<StorageLocationRef?> pickReceiveDirectory() async {
    final Object? value = await _channel.invokeMethod<Object?>(
      'pickReceiveDirectory',
    );
    return value == null ? null : StorageLocationRef.fromPlatformValue(value);
  }

  @override
  Future<StorageLocationRef> validateReceiveLocation(
    StorageLocationRef location,
  ) async {
    if (location.kind != StorageLocationKind.androidDocumentTree) {
      return location.withPermissionState(StoragePermissionState.granted);
    }
    final Object? value = await _channel.invokeMethod<Object?>(
      'validateReceiveDirectory',
      <String, Object?>{'locationRef': location.opaqueValue},
    );
    return StorageLocationRef.fromPlatformValue(value);
  }

  @override
  Future<StorageMeasurement> measureFreeSpace({
    required StorageLocationRef? location,
  }) async {
    final Object? value = await _channel.invokeMethod<Object?>(
      'measureFreeSpace',
      <String, Object?>{'locationRef': location?.opaqueValue},
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

class MethodChannelWindowsStorageGateway implements PlatformStorageGateway {
  MethodChannelWindowsStorageGateway({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'com.nearsend.app/files';

  final MethodChannel _channel;

  @override
  String get platformLabel => 'Windows';

  @override
  bool get supportsDirectorySelection => true;

  @override
  Future<StorageLocationRef?> defaultReceiveLocation() async {
    final Object? value = await _channel.invokeMethod<Object?>(
      'defaultReceiveLocation',
    );
    return value == null ? null : StorageLocationRef.fromPlatformValue(value);
  }

  @override
  Future<StorageLocationRef?> pickReceiveDirectory() async {
    final Object? value = await _channel.invokeMethod<Object?>(
      'pickReceiveDirectory',
    );
    return value == null ? null : StorageLocationRef.fromPlatformValue(value);
  }

  @override
  Future<StorageLocationRef> validateReceiveLocation(
    StorageLocationRef location,
  ) async {
    final Object? value = await _channel.invokeMethod<Object?>(
      'validateReceiveDirectory',
      <String, Object?>{'locationRef': location.opaqueValue},
    );
    return StorageLocationRef.fromPlatformValue(value);
  }

  @override
  Future<StorageMeasurement> measureFreeSpace({
    required StorageLocationRef? location,
  }) async {
    final Object? value = await _channel.invokeMethod<Object?>(
      'measureFreeSpace',
      <String, Object?>{'locationRef': location?.opaqueValue},
    );
    return _measurementFrom(value);
  }
}

StorageMeasurement _measurementFrom(Object? value) {
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
