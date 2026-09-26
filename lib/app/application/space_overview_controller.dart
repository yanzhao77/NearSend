import 'package:flutter/foundation.dart';

import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/platform/platform_storage_gateway.dart';
import 'package:nearsend/platform/storage_location.dart';

class SpaceVolumeOverview {
  const SpaceVolumeOverview({
    required this.volume,
    required this.label,
    required this.availability,
    this.requiredBytes,
  });

  final VolumeId volume;
  final String label;
  final VolumeAvailability availability;
  final int? requiredBytes;

  SpaceVerdict get verdict {
    final int? free = availability.freeBytes;
    final int? required = requiredBytes;
    if (free == null || required == null) return SpaceVerdict.unknown;
    return free >= required
        ? SpaceVerdict.sufficient
        : SpaceVerdict.insufficient;
  }
}

class SpaceOverview {
  const SpaceOverview({required this.volumes, this.location});

  const SpaceOverview.unknown()
    : volumes = const <SpaceVolumeOverview>[
        SpaceVolumeOverview(
          volume: VolumeId('unknown'),
          label: '保存位置',
          availability: VolumeAvailability.unknown(),
        ),
      ],
      location = null;

  final List<SpaceVolumeOverview> volumes;
  final StorageLocationRef? location;

  /// Whether the platform failed to measure capacity. A known free-space value with no active
  /// transfer has no requirement to compare against; that is "not evaluated", not "unknown".
  bool get hasUnknown =>
      volumes.any((SpaceVolumeOverview volume) => !volume.availability.isKnown);
}

class SpaceOverviewController extends ChangeNotifier {
  SpaceOverviewController({PlatformStorageGateway? gateway})
    : gateway = gateway ?? const UnknownPlatformStorageGateway();

  final PlatformStorageGateway gateway;
  SpaceOverview _overview = const SpaceOverview.unknown();
  bool _loading = false;
  Object? _error;

  SpaceOverview get overview => _overview;
  bool get isLoading => _loading;
  Object? get error => _error;

  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final StorageLocationRef? location = await gateway
          .defaultReceiveLocation();
      final StorageMeasurement measurement = await gateway.measureFreeSpace(
        location: location,
      );
      _overview = SpaceOverview(
        volumes: <SpaceVolumeOverview>[
          SpaceVolumeOverview(
            volume: measurement.volume,
            label: measurement.label,
            availability: measurement.availability,
          ),
        ],
        location: location,
      );
    } on Object catch (error) {
      _error = error;
      _overview = const SpaceOverview.unknown();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }
}
