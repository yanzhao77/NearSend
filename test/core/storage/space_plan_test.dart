import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/space_plan.dart';

/// Space planning, `APP_AND_SERVICE_DESIGN.md` §8 and `技术方案 V2.1` §16.2.
///
/// The behaviour worth protecting is the difference between "we checked and it fits"
/// and "we could not check". §8 forbids showing the second as a passed check, so several
/// of these tests exist only to prove `unknown` cannot be read as `sufficient`.
void main() {
  const VolumeId internal = VolumeId('internal');
  const VolumeId sdCard = VolumeId('sd-card');

  const int mib = 1024 * 1024;
  const int gib = 1024 * mib;

  FileSpaceRequest file({
    String id = 'f1',
    required int sizeBytes,
    VolumeId staging = internal,
    VolumeId export = internal,
    int alreadyAllocated = 0,
    bool sourceMustBeStaged = false,
  }) => FileSpaceRequest(
    fileId: id,
    sizeBytes: sizeBytes,
    stagingVolume: staging,
    exportVolume: export,
    stagingAlreadyAllocatedBytes: alreadyAllocated,
    sourceMustBeStaged: sourceMustBeStaged,
  );

  SpacePlan planWith(
    List<FileSpaceRequest> files, {
    required Map<VolumeId, VolumeAvailability> availability,
    VolumeId databaseVolume = internal,
    SpacePlanner planner = const SpacePlanner(),
  }) => planner.plan(
    files: files,
    availability: availability,
    volumeForDatabase: databaseVolume,
  );

  group('explained breakdown', () {
    test('the lines add up to the requirement', () {
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[file(sizeBytes: 100 * mib)],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(10 * gib),
        },
      );

      final VolumeSpacePlan volume = plan.forVolume(internal);
      int summed = 0;
      for (final SpaceLine line in volume.lines) {
        summed += line.bytes;
      }
      expect(
        volume.requiredBytes,
        summed,
        reason:
            'every byte the user is asked to free must appear as a component they can '
            'read, not only in the total',
      );
      expect(volume.lines, isNotEmpty);
    });

    test('every line explains itself', () {
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[file(sizeBytes: 100 * mib)],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(10 * gib),
        },
      );

      for (final SpaceLine line in plan.forVolume(internal).lines) {
        expect(
          line.reason,
          isNotEmpty,
          reason: '${line.need.name} needs a reason',
        );
        expect(line.need.messageKey, startsWith('space.need.'));
      }
    });

    test('an unknown volume in the request is reported, not ignored', () {
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[file(sizeBytes: 1 * mib)],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(10 * gib),
        },
        databaseVolume: sdCard,
      );

      expect(plan.forVolume(sdCard).verdict, SpaceVerdict.unknown);
    });

    test('asking for a volume that is not in the plan is an error', () {
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[file(sizeBytes: 1 * mib)],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(10 * gib),
        },
      );

      expect(() => plan.forVolume(sdCard), throwsArgumentError);
    });
  });

  group('per-volume accounting', () {
    test('staging and the saved copy on one volume are counted twice', () {
      final int size = 100 * mib;
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[file(sizeBytes: size)],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(10 * gib),
        },
      );

      final VolumeSpacePlan volume = plan.forVolume(internal);
      expect(volume.bytesFor(SpaceNeed.unallocatedStaging), size);
      expect(
        volume.bytesFor(SpaceNeed.exportPeak),
        size,
        reason:
            'at export time the staging copy and the saved copy coexist, so the peak is '
            'a second full copy',
      );
      expect(
        volume.requiredBytes,
        greaterThan(2 * size),
        reason: 'the peak plus the database estimate and the margin',
      );
    });

    test('volumes are checked separately, not added together', () {
      final int size = 100 * mib;
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[
          file(sizeBytes: size, staging: internal, export: sdCard),
        ],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(10 * gib),
          sdCard: const VolumeAvailability.known(10 * gib),
        },
      );

      final VolumeSpacePlan staging = plan.forVolume(internal);
      final VolumeSpacePlan target = plan.forVolume(sdCard);

      expect(staging.bytesFor(SpaceNeed.unallocatedStaging), size);
      expect(
        staging.bytesFor(SpaceNeed.exportPeak),
        0,
        reason: 'the saved copy does not land on the staging volume',
      );
      expect(target.bytesFor(SpaceNeed.exportPeak), size);
      expect(
        target.bytesFor(SpaceNeed.unallocatedStaging),
        0,
        reason: 'staging does not land on the target volume',
      );
    });

    test('a 20 GiB same-volume transfer needs close to 40 GiB', () {
      final int size = 20 * gib;
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[file(sizeBytes: size)],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(200 * gib),
        },
      );

      final VolumeSpacePlan volume = plan.forVolume(internal);
      expect(
        volume.requiredBytes,
        greaterThanOrEqualTo(2 * size),
        reason: '§16.2 states a 20 GiB file can need close to 40 GiB',
      );
      expect(
        volume.requiredBytes,
        lessThan(2 * size + 2 * gib),
        reason: 'the extra over two copies is the estimate and the margin only',
      );
      expect(volume.verdict, SpaceVerdict.sufficient);
    });

    test('already allocated staging is not counted again', () {
      final int size = 100 * mib;
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[file(sizeBytes: size, alreadyAllocated: 40 * mib)],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(10 * gib),
        },
      );

      expect(
        plan.forVolume(internal).bytesFor(SpaceNeed.unallocatedStaging),
        60 * mib,
      );
    });

    test('a fully staged file adds no staging requirement', () {
      final int size = 100 * mib;
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[file(sizeBytes: size, alreadyAllocated: size)],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(10 * gib),
        },
      );

      expect(
        plan.forVolume(internal).bytesFor(SpaceNeed.unallocatedStaging),
        0,
      );
      expect(
        plan.forVolume(internal).bytesFor(SpaceNeed.exportPeak),
        size,
        reason: 'the saved copy is still new occupancy',
      );
    });

    test('an over-reported allocation never yields a negative need', () {
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[
          file(sizeBytes: 10 * mib, alreadyAllocated: 50 * mib),
        ],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(10 * gib),
        },
      );

      expect(
        plan.forVolume(internal).bytesFor(SpaceNeed.unallocatedStaging),
        0,
      );
      expect(plan.forVolume(internal).requiredBytes, greaterThan(0));
    });

    test('a source that must be staged is charged where it is copied', () {
      final int size = 100 * mib;
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[file(sizeBytes: size, sourceMustBeStaged: true)],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(10 * gib),
        },
      );

      expect(plan.forVolume(internal).bytesFor(SpaceNeed.sourceStaging), size);
    });
  });

  group('unknown is not a pass', () {
    test('a provider that cannot report space gives unknown', () {
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[file(sizeBytes: 1 * mib)],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.unknown(),
        },
      );

      expect(plan.forVolume(internal).verdict, SpaceVerdict.unknown);
      expect(plan.verdict, SpaceVerdict.unknown);
    });

    test('unknown stays unknown even when the requirement is tiny', () {
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[file(sizeBytes: 1)],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.unknown(),
        },
      );

      expect(
        plan.forVolume(internal).verdict,
        isNot(SpaceVerdict.sufficient),
        reason:
            'a small requirement is not evidence that it fits; §8 forbids showing an '
            'unverifiable volume as a passed check',
      );
      expect(plan.verdict.permitsStartWithoutUserDecision, isFalse);
    });

    test('an unknown volume does not mask a shortfall elsewhere', () {
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[
          file(sizeBytes: 100 * mib, staging: internal, export: sdCard),
        ],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(1 * mib),
          sdCard: const VolumeAvailability.unknown(),
        },
      );

      expect(plan.verdict, SpaceVerdict.insufficient);
      expect(plan.forVolume(internal).verdict, SpaceVerdict.insufficient);
      expect(plan.forVolume(sdCard).verdict, SpaceVerdict.unknown);
    });

    test(
      'only a sufficient verdict permits starting without asking the user',
      () {
        expect(SpaceVerdict.sufficient.permitsStartWithoutUserDecision, isTrue);
        expect(
          SpaceVerdict.insufficient.permitsStartWithoutUserDecision,
          isFalse,
        );
        expect(SpaceVerdict.unknown.permitsStartWithoutUserDecision, isFalse);
      },
    );

    test('each verdict has a distinct message key', () {
      final Set<String> keys = <String>{
        for (final SpaceVerdict verdict in SpaceVerdict.values)
          verdict.messageKey,
      };
      expect(keys.length, SpaceVerdict.values.length);
    });
  });

  group('shortfall', () {
    test('a known shortfall reports the gap', () {
      final int size = 100 * mib;
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[file(sizeBytes: size)],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(1 * mib),
        },
      );

      final VolumeSpacePlan volume = plan.forVolume(internal);
      expect(volume.verdict, SpaceVerdict.insufficient);
      expect(
        volume.shortfallBytes,
        volume.requiredBytes - 1 * mib,
        reason: 'the user needs to know how much to free',
      );
    });

    test('a sufficient plan reports no shortfall', () {
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[file(sizeBytes: 1 * mib)],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(10 * gib),
        },
      );

      expect(plan.forVolume(internal).shortfallBytes, isNull);
    });

    test('an unknown volume reports no shortfall', () {
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[file(sizeBytes: 1 * mib)],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.unknown(),
        },
      );

      expect(
        plan.forVolume(internal).shortfallBytes,
        isNull,
        reason: 'a gap cannot be stated against a reading that does not exist',
      );
    });

    test('freed space flips the same plan to sufficient', () {
      final int size = 100 * mib;
      final List<FileSpaceRequest> files = <FileSpaceRequest>[
        file(sizeBytes: size),
      ];

      final SpacePlan before = planWith(
        files,
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(1 * mib),
        },
      );
      expect(before.verdict, SpaceVerdict.insufficient);

      // The same files re-checked after the user frees room. §16.2 requires the check to
      // be repeated before each file and before export, so it must be a pure function of
      // the current reading.
      final SpacePlan after = planWith(
        files,
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(10 * gib),
        },
      );
      expect(after.verdict, SpaceVerdict.sufficient);
    });
  });

  group('safety margin', () {
    const SafetyMarginPolicy policy = SafetyMarginPolicy();

    test('a small transfer gets the 256 MiB floor', () {
      expect(
        policy.forFootprint(10 * mib),
        SafetyMarginPolicy.defaultMinimumBytes,
      );
    });

    test('a large transfer gets the percentage instead', () {
      final int footprint = 100 * gib;
      expect(policy.forFootprint(footprint), 1 * gib);
      expect(1 * gib, greaterThan(SafetyMarginPolicy.defaultMinimumBytes));
    });

    test('the percentage branch always rounds up', () {
      const SafetyMarginPolicy onePercent = SafetyMarginPolicy(
        minimumBytes: 0,
        percentOfFootprint: 1,
      );
      expect(
        onePercent.forFootprint(101),
        2,
        reason: '1% of 101 is 1.01, which must not be rounded down to 1',
      );
      expect(onePercent.forFootprint(100), 1);
      expect(onePercent.forFootprint(1), 1);
    });

    test('an empty footprint still gets the floor', () {
      expect(policy.forFootprint(0), SafetyMarginPolicy.defaultMinimumBytes);
    });

    test('the margin is charged on every volume separately', () {
      final int size = 100 * mib;
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[
          file(sizeBytes: size, staging: internal, export: sdCard),
        ],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(10 * gib),
          sdCard: const VolumeAvailability.known(10 * gib),
        },
      );

      for (final VolumeSpacePlan volume in plan.volumes) {
        expect(
          volume.bytesFor(SpaceNeed.safetyMargin),
          policy.forFootprint(
            volume.requiredBytes - volume.bytesFor(SpaceNeed.safetyMargin),
          ),
          reason: 'the margin is a per-volume policy, not a task-wide one',
        );
      }
    });

    test('the margin line says it is a policy and not a guarantee', () {
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[file(sizeBytes: 1 * mib)],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(10 * gib),
        },
      );

      final SpaceLine margin = plan
          .forVolume(internal)
          .lines
          .firstWhere((SpaceLine line) => line.need == SpaceNeed.safetyMargin);
      expect(margin.reason, contains('not a guarantee'));
    });
  });

  group('database estimate', () {
    test('a zero-byte file still costs rows', () {
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[file(sizeBytes: 0)],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(10 * gib),
        },
      );

      final VolumeSpacePlan volume = plan.forVolume(internal);
      expect(volume.bytesFor(SpaceNeed.unallocatedStaging), 0);
      expect(volume.bytesFor(SpaceNeed.exportPeak), 0);
      expect(
        volume.bytesFor(SpaceNeed.databaseEstimate),
        DatabaseFootprintEstimate.defaultPerFileBytes,
        reason:
            '§5.3 gives a zero-byte file no chunks but it is still a file row',
      );
    });

    test('chunk rows are counted at the protocol chunk size', () {
      final int size = 4 * mib;
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[file(sizeBytes: size)],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(10 * gib),
        },
      );

      expect(
        plan.forVolume(internal).bytesFor(SpaceNeed.databaseEstimate),
        DatabaseFootprintEstimate.defaultPerFileBytes +
            DatabaseFootprintEstimate.defaultPerChunkBytes,
        reason: '4 MiB at the default 4 MiB chunk size is exactly one chunk',
      );
    });

    test('the estimate is conservative against the real schema', () {
      final Directory dir = Directory.systemTemp.createTempSync(
        'nearsend-space-',
      );
      addTearDown(() {
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
      });

      final NearSendDatabase database = NearSendDatabase.open(
        path: '${dir.path}${Platform.pathSeparator}space.db',
      );
      addTearDown(database.close);
      final ChunkRepository chunks = ChunkRepository(database);

      const String taskId = '00000000-0000-4000-8000-0000000000c1';
      chunks.registerTask(
        taskId: taskId,
        role: 'receiver',
        direction: 'client_to_server',
        state: TransferState.ready,
        protocolMajor: 1,
        protocolMinor: 0,
      );

      final int pageSize =
          database.db.select('PRAGMA page_size;').first['page_size'] as int;
      const DatabaseFootprintEstimate estimate = DatabaseFootprintEstimate();

      // Two sizes, so a constant that happens to fit one page-granular measurement
      // cannot pass by luck.
      int index = 0;
      for (final int chunkCount in <int>[200, 1000]) {
        final int before =
            database.db.select('PRAGMA page_count;').first['page_count'] as int;
        const int chunkBytes = 4;
        final int fileBytes = chunkCount * chunkBytes;
        chunks.registerFile(
          FrozenFileRegistration(
            taskId: taskId,
            fileId:
                '00000000-0000-4000-8000-0000000001${index.toString().padLeft(2, '0')}',
            relativePath: 'measured-$index.bin',
            sizeBytes: fileBytes,
            fileSha256: 'a' * 64,
            chunkManifestDigest: 'b' * 64,
            chunks: <ChunkRecord>[
              for (int i = 0; i < chunkCount; i++)
                ChunkRecord(index: i, length: chunkBytes, sha256: 'c' * 64),
            ],
            chunkSizeBytes: chunkBytes,
          ),
        );
        final int after =
            database.db.select('PRAGMA page_count;').first['page_count'] as int;
        final int measured = (after - before) * pageSize;
        final int estimated = estimate.forFile(fileBytes, chunkBytes);

        expect(
          estimated,
          greaterThanOrEqualTo(measured),
          reason:
              'the estimate must not understate what the v1 schema measurably costs; '
              'for $chunkCount chunks it measured $measured B against an estimate of '
              '$estimated B',
        );
        index++;
      }
    });
  });

  group('database volume', () {
    test('the estimate lands only on the database volume', () {
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[
          file(sizeBytes: 1 * mib, staging: internal, export: internal),
        ],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(10 * gib),
          sdCard: const VolumeAvailability.known(10 * gib),
        },
        databaseVolume: sdCard,
      );

      expect(plan.forVolume(internal).bytesFor(SpaceNeed.databaseEstimate), 0);
      expect(
        plan.forVolume(sdCard).bytesFor(SpaceNeed.databaseEstimate),
        greaterThan(0),
      );
    });

    test('a plan with no files still reports the volumes it touches', () {
      final SpacePlan plan = planWith(
        const <FileSpaceRequest>[],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(10 * gib),
        },
      );

      expect(plan.volumes, hasLength(1));
      expect(
        plan.forVolume(internal).bytesFor(SpaceNeed.databaseEstimate),
        0,
        reason: 'an empty task writes no rows',
      );
      expect(plan.forVolume(internal).verdict, SpaceVerdict.sufficient);
    });
  });

  group('volume identity', () {
    test('the same volume id is one plan', () {
      final SpacePlan plan = planWith(
        <FileSpaceRequest>[
          file(id: 'a', sizeBytes: 10 * mib),
          file(id: 'b', sizeBytes: 20 * mib),
        ],
        availability: <VolumeId, VolumeAvailability>{
          internal: const VolumeAvailability.known(10 * gib),
        },
      );

      expect(plan.volumes, hasLength(1));
      expect(
        plan.forVolume(internal).bytesFor(SpaceNeed.unallocatedStaging),
        30 * mib,
      );
    });

    test('volume ids compare by value', () {
      expect(const VolumeId('x'), const VolumeId('x'));
      expect(const VolumeId('x').hashCode, const VolumeId('x').hashCode);
      expect(const VolumeId('x'), isNot(const VolumeId('y')));
    });

    test(
      'a volume id does not expose a filesystem path in its string form',
      () {
        expect(
          const VolumeId('provider:primary').toString(),
          contains('provider'),
        );
      },
    );
  });

  group('request validation', () {
    test(
      'allocated bytes larger than the file are clamped, not trusted blindly',
      () {
        final FileSpaceRequest request = file(
          sizeBytes: 10 * mib,
          alreadyAllocated: 999 * mib,
        );
        expect(request.unallocatedStagingBytes, 0);
      },
    );

    test('the request keeps the size the manifest froze', () {
      final FileSpaceRequest request = file(sizeBytes: 7 * mib);
      expect(request.sizeBytes, 7 * mib);
    });
  });
}
