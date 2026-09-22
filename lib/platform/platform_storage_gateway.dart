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
