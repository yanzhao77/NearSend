/// Space planning, `APP_AND_SERVICE_DESIGN.md` §8 and `技术方案 V2.1` §16.2.
///
/// ## Why this returns a breakdown rather than a boolean
///
/// §8 is explicit: "空间计划输出每个卷的解释性明细……不能只返回布尔值". The user is being
/// asked to make room before a transfer starts, and "空间不足" without the components is
/// not an answer they can act on. So every byte in this model carries the [SpaceNeed] it
/// belongs to and a human-readable reason.
///
/// ## The rule that matters most
///
/// **`unknown` is not `sufficient`.** When a storage provider cannot report its free
/// space - which §16.1 says must be shown as "无法确认可用空间" - the plan must say so and
/// the UI must ask the user to accept the risk. §8: "不能显示「检查通过」". A planner that
/// folded `unknown` into "fine, proceed" would silently convert an unknown risk into an
/// assurance, which is the failure mode this type exists to prevent.
///
/// ## What the estimate is and is not
///
/// The requirement is a **conservative peak**, not a reservation: at export time the
/// staging copy and the exported copy can coexist, so a same-volume export is counted
/// twice. §16.2 accepts this cost rather than trading away integrity, and states plainly
/// that the safety margin "不是空间足够的保证" - other applications keep consuming space,
/// so the check is repeated before each file and before export.
library;

import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';

/// Identifies the storage volume or provider a requirement is accounted against.
///
/// Compared by value, because that comparison is what decides whether staging and the
/// exported copy can coexist. Where a platform cannot report a stable provider identity,
/// the caller must pass a conservative identifier that groups anything that might share
/// space; grouping too much only over-estimates, which is the safe direction.
class VolumeId {
  const VolumeId(this.value);

  /// An opaque, non-sensitive handle. Never a full local path, which §5 keeps out of
  /// diagnostics and logs.
  final String value;

  @override
  bool operator ==(Object other) => other is VolumeId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'VolumeId($value)';
}

/// The component of a requirement a byte count belongs to.
///
/// These are exactly the terms of the formula in §16.2, kept separate so the UI can
/// explain the total instead of asserting it.
enum SpaceNeed {
  /// Staging bytes that are not allocated yet, on the staging volume.
  ///
  /// Already-allocated staging is subtracted rather than counted again: it is part of
  /// the volume's present usage, not of the new requirement (§16.2: 已有实际分配的临时
  /// 文件空间不重复扣减).
  unallocatedStaging('space.need.unallocatedStaging'),

  /// The peak extra occupancy of writing the user's copy.
  ///
  /// When the target is the same volume as staging, this is a full second copy of the
  /// file; when it is a different volume, it lands there instead.
  exportPeak('space.need.exportPeak'),

  /// Extra room to stage a source that cannot be read in place.
  ///
  /// Zero on the receiving side; it is a sending-side term of the same formula, kept
  /// here so both directions are planned by one implementation.
  sourceStaging('space.need.sourceStaging'),

  /// Estimated cost of the task, file and chunk rows this transfer will write.
  databaseEstimate('space.need.databaseEstimate'),

  /// A per-volume policy margin, not a guarantee (§16.2).
  safetyMargin('space.need.safetyMargin');

  const SpaceNeed(this.messageKey);

  /// Stable key for the safe, localised explanation line.
  final String messageKey;
}

/// One explained component of a volume's requirement.
class SpaceLine {
  const SpaceLine({
    required this.need,
    required this.bytes,
    required this.reason,
  });

  final SpaceNeed need;
  final int bytes;

  /// Why this many bytes, in terms the user or a reviewer can check.
  final String reason;

  @override
  String toString() => '${need.name}=$bytes ($reason)';
}

/// The outcome of comparing a requirement against what a volume can offer.
enum SpaceVerdict {
  /// The requirement fits in a **known** amount of free space.
  sufficient('space.sufficient'),

  /// The requirement does not fit; [VolumeSpacePlan.shortfallBytes] is the gap.
  insufficient('space.insufficient'),

  /// The provider could not report its free space. **Not** a pass.
  ///
  /// The UI must ask the user to confirm the risk (§16.1) and the transfer must keep
  /// handling write failures as they happen (§8).
  unknown('space.unknown');

  const SpaceVerdict(this.messageKey);

  final String messageKey;

  /// Whether this verdict lets the transfer start without a user decision.
  ///
  /// Only [sufficient] does. Named for the decision rather than for the enum so that a
  /// caller cannot read `unknown` as "probably fine": §8 forbids showing `unknown` as a
  /// passed check.
  bool get permitsStartWithoutUserDecision => this == SpaceVerdict.sufficient;
}

/// What a volume can offer, as reported by the platform.
///
/// [freeBytes] is null when the provider cannot be queried. Do not substitute an
/// estimate: §16.1 requires the unknown case to be surfaced, not filled in.
class VolumeAvailability {
  const VolumeAvailability.known(int this.freeBytes);

  /// The provider could not report its free space.
  const VolumeAvailability.unknown() : freeBytes = null;

  final int? freeBytes;

  bool get isKnown => freeBytes != null;

  /// Never treats an unknown volume as empty.
  bool canFit(int requiredBytes) {
    final int? free = freeBytes;
    return free != null && requiredBytes <= free;
  }
}

/// What one file needs, and where.
class FileSpaceRequest {
  const FileSpaceRequest({
    required this.fileId,
    required this.sizeBytes,
    required this.stagingVolume,
    required this.exportVolume,
    this.stagingAlreadyAllocatedBytes = 0,
    this.sourceMustBeStaged = false,
  });

  final String fileId;

  /// The transfer size from the frozen manifest.
  final int sizeBytes;

  final VolumeId stagingVolume;

  /// Where the user's copy will be written; may equal [stagingVolume].
  final VolumeId exportVolume;

  /// Staging bytes the platform reports as **actually allocated** for this file.
  ///
  /// Must come from the platform's allocation accounting. §16.2 is explicit that a
  /// sparse file's logical length must not be counted as allocated, so this value must
  /// not be derived from [sizeBytes].
  final int stagingAlreadyAllocatedBytes;

  /// Whether the source has to be copied into staging before it can be read.
  ///
  /// A sending-side term; false on the receiving side.
  final bool sourceMustBeStaged;

  /// Staging this file still needs.
  int get unallocatedStagingBytes {
    final int remaining = sizeBytes - stagingAlreadyAllocatedBytes;
    return remaining > 0 ? remaining : 0;
  }
}

/// How much the database is estimated to grow per file and per chunk.
///
/// Deliberately configurable and deliberately an estimate: §8 asks for a "数据库估算",
/// and pretending to more precision than the engine gives would be a false assurance.
/// The defaults are conservative relative to what the current schema measurably costs.
class DatabaseFootprintEstimate {
  const DatabaseFootprintEstimate({
    this.perFileBytes = defaultPerFileBytes,
    this.perChunkBytes = defaultPerChunkBytes,
  });

  /// Metadata row plus its index entry.
  final int perFileBytes;

  /// One chunk row plus its `(file_id, state)` index entry.
  final int perChunkBytes;

  /// Conservative against the measured cost of a `files` row in the v1 schema.
  static const int defaultPerFileBytes = 1024;

  /// Conservative against the measured cost of a `chunks` row in the v1 schema.
  ///
  /// A 200-chunk file was measured to grow the database by 53,248 B, which is about
  /// 266 B per chunk including the file row. The constant is set above that with room
  /// for page-granular allocation, and a test asserts the estimate covers measurements
  /// at two different chunk counts.
  static const int defaultPerChunkBytes = 320;

  /// Estimated bytes for one file of [sizeBytes], chunked at [chunkSizeBytes].
  int forFile(int sizeBytes, int chunkSizeBytes) =>
      perFileBytes +
      perChunkBytes * chunkCountForSize(sizeBytes, chunkSizeBytes);
}

/// The policy margin added per volume.
///
/// §16.2: `max(256 MiB, 1% of the expected new occupancy)`, adjustable policy, and
/// explicitly **not** a guarantee that the space is enough.
class SafetyMarginPolicy {
  const SafetyMarginPolicy({
    this.minimumBytes = defaultMinimumBytes,
    this.percentOfFootprint = defaultPercent,
  });

  final int minimumBytes;
  final int percentOfFootprint;

  static const int defaultMinimumBytes = 256 * 1024 * 1024;
  static const int defaultPercent = 1;

  /// The margin for a volume whose new occupancy is [footprintBytes].
  int forFootprint(int footprintBytes) {
    if (footprintBytes <= 0) {
      return minimumBytes;
    }
    // Ceiling division, so a positive footprint never rounds the margin down to zero.
    final int proportional = (footprintBytes * percentOfFootprint + 99) ~/ 100;
    return proportional > minimumBytes ? proportional : minimumBytes;
  }
}

/// One volume's requirement, with its components.
class VolumeSpacePlan {
  const VolumeSpacePlan({
    required this.volume,
    required this.lines,
    required this.requiredBytes,
    required this.availability,
    required this.verdict,
    required this.shortfallBytes,
  });

  final VolumeId volume;
  final List<SpaceLine> lines;

  /// The sum of [lines]. Every byte the user is being asked to free is in here.
  final int requiredBytes;

  final VolumeAvailability availability;

  final SpaceVerdict verdict;

  /// How much more is needed, or null when the verdict is not [SpaceVerdict.insufficient].
  final int? shortfallBytes;

  /// The bytes of one component.
  int bytesFor(SpaceNeed need) {
    int total = 0;
    for (final SpaceLine line in lines) {
      if (line.need == need) {
        total += line.bytes;
      }
    }
    return total;
  }

  @override
  String toString() =>
      'VolumeSpacePlan(${volume.value}, ${verdict.name}, '
      'required=$requiredBytes, available=${availability.freeBytes})';
}

/// Every volume a transfer touches.
class SpacePlan {
  const SpacePlan(this.volumes);

  final List<VolumeSpacePlan> volumes;

  VolumeSpacePlan forVolume(VolumeId volume) {
    for (final VolumeSpacePlan plan in volumes) {
      if (plan.volume == volume) {
        return plan;
      }
    }
    throw ArgumentError.value(volume.value, 'volume', 'not part of this plan');
  }

  /// The verdict a transfer should act on, taking the worst of the volumes.
  ///
  /// A shortfall anywhere blocks; otherwise an unknown anywhere is reported as unknown
  /// rather than averaged away, because one unverifiable volume is still unverifiable.
  SpaceVerdict get verdict {
    SpaceVerdict worst = SpaceVerdict.sufficient;
    for (final VolumeSpacePlan plan in volumes) {
      if (plan.verdict == SpaceVerdict.insufficient) {
        return SpaceVerdict.insufficient;
      }
      if (plan.verdict == SpaceVerdict.unknown) {
        worst = SpaceVerdict.unknown;
      }
    }
    return worst;
  }

  /// Volumes that cannot accept the transfer as planned.
  List<VolumeSpacePlan> get blockedVolumes => <VolumeSpacePlan>[
    for (final VolumeSpacePlan plan in volumes)
      if (plan.verdict != SpaceVerdict.sufficient) plan,
  ];
}

/// Builds a [SpacePlan] from per-file requests and per-volume availability.
class SpacePlanner {
  const SpacePlanner({
    this.databaseFootprint = const DatabaseFootprintEstimate(),
    this.safetyMargin = const SafetyMarginPolicy(),
    this.chunkSizeBytes = ProtocolLimits.chunkSizeBytes,
  });

  final DatabaseFootprintEstimate databaseFootprint;
  final SafetyMarginPolicy safetyMargin;
  final int chunkSizeBytes;

  /// Plans a transfer.
  ///
  /// [volumeForDatabase] is where the task's rows are written; a volume absent from
  /// [availability] is treated as unknown, never as empty.
  SpacePlan plan({
    required List<FileSpaceRequest> files,
    required Map<VolumeId, VolumeAvailability> availability,
    required VolumeId volumeForDatabase,
  }) {
    // Preserve first-seen order so the UI shows volumes in a stable order.
    final List<VolumeId> order = <VolumeId>[];
    void note(VolumeId volume) {
      if (!order.contains(volume)) {
        order.add(volume);
      }
    }

    for (final FileSpaceRequest file in files) {
      note(file.stagingVolume);
      note(file.exportVolume);
    }
    note(volumeForDatabase);

    final List<VolumeSpacePlan> plans = <VolumeSpacePlan>[];
    for (final VolumeId volume in order) {
      final List<SpaceLine> base = <SpaceLine>[];

      for (final FileSpaceRequest file in files) {
        if (file.stagingVolume == volume && file.unallocatedStagingBytes > 0) {
          base.add(
            SpaceLine(
              need: SpaceNeed.unallocatedStaging,
              bytes: file.unallocatedStagingBytes,
              reason: file.stagingAlreadyAllocatedBytes > 0
                  ? '${file.fileId}: ${file.sizeBytes} B less the '
                        '${file.stagingAlreadyAllocatedBytes} B already allocated'
                  : '${file.fileId}: full staging copy of ${file.sizeBytes} B',
            ),
          );
        }
        if (file.exportVolume == volume) {
          base.add(
            SpaceLine(
              need: SpaceNeed.exportPeak,
              bytes: file.sizeBytes,
              reason: file.exportVolume == file.stagingVolume
                  ? '${file.fileId}: the saved copy coexists with staging on this volume'
                  : '${file.fileId}: saved copy lands on this volume',
            ),
          );
        }
        if (file.sourceMustBeStaged &&
            file.stagingVolume == volume &&
            file.sizeBytes > 0) {
          base.add(
            SpaceLine(
              need: SpaceNeed.sourceStaging,
              bytes: file.sizeBytes,
              reason:
                  '${file.fileId}: the source cannot be read in place, so it must be '
                  'copied before it can be sent',
            ),
          );
        }
      }

      if (volume == volumeForDatabase && files.isNotEmpty) {
        int estimated = 0;
        for (final FileSpaceRequest file in files) {
          estimated += databaseFootprint.forFile(
            file.sizeBytes,
            chunkSizeBytes,
          );
        }
        base.add(
          SpaceLine(
            need: SpaceNeed.databaseEstimate,
            bytes: estimated,
            reason:
                'task, file and chunk rows for ${files.length} file(s), estimated',
          ),
        );
      }

      int footprint = 0;
      for (final SpaceLine line in base) {
        footprint += line.bytes;
      }

      final int margin = safetyMargin.forFootprint(footprint);
      final List<SpaceLine> lines = <SpaceLine>[
        ...base,
        SpaceLine(
          need: SpaceNeed.safetyMargin,
          bytes: margin,
          reason:
              'policy margin: max(${safetyMargin.minimumBytes} B, '
              '${safetyMargin.percentOfFootprint}% of the new occupancy above). '
              'Lowers risk; it is not a guarantee that the space is enough.',
        ),
      ];

      final int required = footprint + margin;
      final VolumeAvailability available =
          availability[volume] ?? const VolumeAvailability.unknown();

      plans.add(
        VolumeSpacePlan(
          volume: volume,
          lines: lines,
          requiredBytes: required,
          availability: available,
          verdict: _verdict(required, available),
          shortfallBytes: available.isKnown && required > available.freeBytes!
              ? required - available.freeBytes!
              : null,
        ),
      );
    }

    return SpacePlan(plans);
  }

  /// Compares a requirement against what a volume reports.
  ///
  /// The unknown case is decided **before** any comparison, so there is no path on which
  /// a missing reading is treated as a passing one.
  static SpaceVerdict _verdict(
    int requiredBytes,
    VolumeAvailability availability,
  ) {
    final int? free = availability.freeBytes;
    if (free == null) {
      return SpaceVerdict.unknown;
    }
    return requiredBytes <= free
        ? SpaceVerdict.sufficient
        : SpaceVerdict.insufficient;
  }
}
