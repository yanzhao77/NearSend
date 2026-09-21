import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/network/manifest_staging_registry.dart';
import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/manifest_page.dart';
import 'package:nearsend/core/protocol/manifest_staging.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

/// Finding the staging for a transfer, and §6's thirty-minute window.
///
/// §6: "首次收到内容后 30 分钟 staging 未完成则清理并撤销该提议；**不影响已经冻结的任务**".
/// The predicate existed with nothing calling it, so the point of these tests is mostly the
/// *second* clause: a window that also discarded a sealed manifest would revoke a proposal the
/// user had already completed, and the sentence is emphatic that it must not.
void main() {
  late Directory dir;
  late NearSendDatabase database;
  late ChunkRepository tasks;
  late TransferRepository transfers;
  late int clock;
  late ManifestStagingRegistry registry;

  const String transferId = '11111111-2222-4333-8444-555555555555';
  const String otherTransferId = '22222222-3333-4444-8555-666666666666';

  String uuid(int n) =>
      '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

  List<ChunkRecord> chunksFor(int sizeBytes) => <ChunkRecord>[
    for (
      int i = 0;
      i < chunkCountForSize(sizeBytes, ProtocolLimits.chunkSizeBytes);
      i++
    )
      ChunkRecord(
        index: i,
        length: chunkLengthForIndex(
          sizeBytes,
          ProtocolLimits.chunkSizeBytes,
          i,
        ),
        sha256: (i + 1).toRadixString(16).padLeft(64, '0'),
      ),
  ];

  ManifestFile file(int n, int sizeBytes) {
    final List<ChunkRecord> chunks = chunksFor(sizeBytes);
    return ManifestFile(
      fileId: uuid(n),
      relativePath: 'file-$n.bin',
      sizeBytes: sizeBytes,
      chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
      chunkCount: chunks.length,
      fileSha256: (n + 100).toRadixString(16).padLeft(64, '0'),
      chunkManifestDigest: ChunkManifestCodec.digest(
        chunks: chunks,
        sizeBytes: sizeBytes,
        chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
      ),
    );
  }

  final List<ManifestFile> files = <ManifestFile>[file(0, 4)];
  final String digest = FrozenManifest(
    protocolMajor: ProtocolLimits.protocolMajor,
    protocolMinor: ProtocolLimits.protocolMinor,
    transferId: transferId,
    files: files,
  ).manifestDigest;

  ManifestFilePage pageFor(String forTransfer, String forDigest) =>
      ManifestFilePage(
        manifestDigest: forDigest,
        startIndex: 0,
        items: forTransfer == transferId ? files : <ManifestFile>[file(9, 4)],
      );

  void register(
    String id, {
    String? manifestDigest,
    String direction = 'client_to_server',
  }) {
    tasks.registerTask(
      taskId: id,
      role: 'receiver',
      direction: direction,
      state: TransferState.staging,
      protocolMajor: ProtocolLimits.protocolMajor,
      protocolMinor: ProtocolLimits.protocolMinor,
      manifestDigest: manifestDigest,
      nowMillis: clock,
    );
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nearsend-registry-');
    database = NearSendDatabase.open(
      path: '${dir.path}${Platform.pathSeparator}registry.db',
    );
    tasks = ChunkRepository(database);
    transfers = TransferRepository(database);
    clock = 1000;
    registry = ManifestStagingRegistry(transfers: transfers, now: () => clock);
  });

  tearDown(() {
    database.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  group('creating staging from the declaration', () {
    test('carries the declared digest and protocol version', () {
      register(transferId, manifestDigest: digest);
      final ManifestStaging staging = registry.stagingFor(transferId);

      expect(staging.transferId, transferId);
      expect(staging.manifestDigest, digest);
      expect(staging.protocolMajor, ProtocolLimits.protocolMajor);
      expect(staging.protocolMinor, ProtocolLimits.protocolMinor);
      expect(staging.isSealed, isFalse);
      expect(registry.stagedTransferCount, 1);
    });

    test('returns the same staging on the next call', () {
      // The pages of one transfer arrive across many requests, so this is what makes the
      // second request accumulate onto the first.
      register(transferId, manifestDigest: digest);
      final ManifestStaging first = registry.stagingFor(transferId);
      first.addPage(pageFor(transferId, digest), nowMillis: clock);

      final ManifestStaging second = registry.stagingFor(transferId);
      expect(identical(first, second), isTrue);
      expect(second.stagedFileCount, 1);
    });

    test('two transfers have independent staging', () {
      register(transferId, manifestDigest: digest);
      register(otherTransferId, manifestDigest: digest);

      registry
          .stagingFor(transferId)
          .addPage(pageFor(transferId, digest), nowMillis: clock);
      expect(registry.stagingFor(otherTransferId).stagedFileCount, 0);
      expect(registry.stagedTransferCount, 2);
    });

    test('an unknown transfer is NOT_FOUND', () {
      expect(
        () => registry.stagingFor(transferId),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.notFound,
          ),
        ),
        reason:
            '§7 answers an unknown or unauthorised resource the same way, so this cannot '
            'be used to learn which transfer ids exist',
      );
    });

    test('a transfer with no declared digest is refused', () {
      register(transferId);
      expect(
        () => registry.stagingFor(transferId),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.invalidState,
          ),
        ),
      );
    });
  });

  group("§6's thirty-minute window", () {
    test('a proposal is usable inside the window', () {
      register(transferId, manifestDigest: digest);
      registry
          .stagingFor(transferId)
          .addPage(pageFor(transferId, digest), nowMillis: clock);

      clock += ProtocolLimits.stagingTimeoutSeconds * 1000 - 1;
      expect(registry.stagingFor(transferId).stagedFileCount, 1);
    });

    test('a proposal past the window is TASK_EXPIRED and forgotten', () {
      register(transferId, manifestDigest: digest);
      registry
          .stagingFor(transferId)
          .addPage(pageFor(transferId, digest), nowMillis: clock);

      clock += ProtocolLimits.stagingTimeoutSeconds * 1000;
      expect(
        () => registry.stagingFor(transferId),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.taskExpired,
          ),
        ),
        reason:
            '§6 discards the proposal; §11 pairs TASK_EXPIRED with 410 and "do not silently '
            'create a duplicate task"',
      );
      expect(
        registry.stagedTransferCount,
        0,
        reason: 'the refused proposal was dropped rather than left to be refused again',
      );
    });

    test('the window runs from the first content, not from the transfer', () {
      // A transfer created long ago but never uploaded to is not expired: §6 starts the
      // window at "首次收到内容".
      register(transferId, manifestDigest: digest);
      clock += ProtocolLimits.stagingTimeoutSeconds * 1000 * 5;
      expect(
        registry.stagingFor(transferId).firstContentAtMillis,
        isNull,
        reason: 'no page has arrived yet, so there is nothing to expire',
      );
    });

    test('a sealed manifest is not subject to the window', () {
      // §6: "不影响已经冻结的任务". Expiring here would revoke a proposal the user already
      // completed, and the same rule is why cleanup must not touch frozen manifest pages.
      register(transferId, manifestDigest: digest);
      final ManifestStaging staging = registry.stagingFor(transferId);
      for (final ManifestFilePage page in ManifestPager.filePages(
        manifestDigest: digest,
        files: files,
      )) {
        staging.addPage(page, nowMillis: clock);
      }
      for (final ManifestFile f in files) {
        for (final ManifestChunkPage page in ManifestPager.chunkPages(
          manifestDigest: digest,
          fileId: f.fileId,
          chunks: chunksFor(f.sizeBytes),
        )) {
          staging.addPage(page, nowMillis: clock);
        }
      }
      staging.seal();
      expect(staging.isSealed, isTrue);

      clock += ProtocolLimits.stagingTimeoutSeconds * 1000 * 10;
      expect(
        registry.stagingFor(transferId).isSealed,
        isTrue,
        reason: 'a frozen manifest is a conclusion, not an unfinished proposal',
      );
      expect(registry.sealedTransferCount, 1);
    });

    test('discard forgets a transfer whether sealed or not', () {
      register(transferId, manifestDigest: digest);
      registry.stagingFor(transferId);
      expect(registry.stagedTransferCount, 1);

      registry.discard(transferId);
      expect(registry.stagedTransferCount, 0);
      expect(registry.sealedTransferCount, 0);
    });
  });

  group('bounded process-local staging', () {
    test('refuses the next proposal at the configured concurrency limit', () {
      register(transferId, manifestDigest: digest);
      register(otherTransferId, manifestDigest: digest);
      final ManifestStagingRegistry bounded = ManifestStagingRegistry(
        transfers: transfers,
        now: () => clock,
        maxConcurrentTransfers: 1,
      );

      bounded.stagingFor(transferId);
      expect(
        () => bounded.stagingFor(otherTransferId),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.resourceLimit,
          ),
        ),
      );
    });

    test(
      'expired incomplete staging is swept before the concurrency check',
      () {
        register(transferId, manifestDigest: digest);
        register(otherTransferId, manifestDigest: digest);
        final ManifestStagingRegistry bounded = ManifestStagingRegistry(
          transfers: transfers,
          now: () => clock,
          maxConcurrentTransfers: 1,
        );
        bounded.addPage(transferId, pageFor(transferId, digest));

        clock += ProtocolLimits.stagingTimeoutSeconds * 1000;
        expect(bounded.stagingFor(otherTransferId), isA<ManifestStaging>());
        expect(bounded.stagedTransferCount, 1);
      },
    );

    test(
      'crossing the retained-record budget releases the failed proposal',
      () {
        register(transferId, manifestDigest: digest);
        final ManifestStagingRegistry bounded = ManifestStagingRegistry(
          transfers: transfers,
          now: () => clock,
          maxRetainedEntries: 1,
        );
        bounded.addPage(transferId, pageFor(transferId, digest));

        final ManifestChunkPage chunks = ManifestPager.chunkPages(
          manifestDigest: digest,
          fileId: files.single.fileId,
          chunks: chunksFor(files.single.sizeBytes),
        ).single;
        expect(
          () => bounded.addPage(transferId, chunks),
          throwsA(
            isA<ProtocolViolation>().having(
              (ProtocolViolation e) => e.code,
              'code',
              ProtocolErrorCode.resourceLimit,
            ),
          ),
        );
        expect(bounded.stagedTransferCount, 0);
        expect(bounded.retainedEntryCount, 0);
      },
    );
  });
}
