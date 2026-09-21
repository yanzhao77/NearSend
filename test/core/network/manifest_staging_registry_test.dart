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
import 'package:nearsend/core/storage/storage_schema.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

/// Finding the staging for a transfer, §6's thirty-minute window, and - new in this batch -
/// the two properties ADR-0004 asked for: an unsealed proposal continues after a restart, and a
/// sealed manifest stays readable across one.
///
/// §6: "首次收到内容后 30 分钟 staging 未完成则清理并撤销该提议；**不影响已经冻结的任务**".
/// The predicate existed with nothing calling it, so the point of those tests is mostly the
/// *second* clause: a window that also discarded a sealed manifest would revoke a proposal the
/// user had already completed, and the sentence is emphatic that it must not.
///
/// The restart tests are the reason this file was rewritten. Under the in-memory registry a
/// "restart" could only be simulated, and what it showed was that the manifest was gone; now a
/// second [NearSendDatabase] opening the same path is a real restart, and the assertions are
/// about what a client can still do afterwards.
void main() {
  late Directory dir;
  late String dbPath;
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

  /// Every page of [forTransfer]'s manifest, files first and then chunks.
  List<ManifestPage> fullManifest(String forTransfer, List<ManifestFile> its) {
    return <ManifestPage>[
      for (final ManifestFilePage page in ManifestPager.filePages(
        manifestDigest: digest,
        files: its,
      ))
        page,
      for (final ManifestFile f in its)
        for (final ManifestChunkPage page in ManifestPager.chunkPages(
          manifestDigest: digest,
          fileId: f.fileId,
          chunks: chunksFor(f.sizeBytes),
        ))
          page,
    ];
  }

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

  ManifestStagingRegistry openRegistry({
    int maxConcurrentTransfers = 8,
    int maxRetainedEntries = 262144,
  }) => ManifestStagingRegistry(
    transfers: transfers,
    now: () => clock,
    maxConcurrentTransfers: maxConcurrentTransfers,
    maxRetainedEntries: maxRetainedEntries,
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nearsend-registry-');
    dbPath = '${dir.path}${Platform.pathSeparator}registry.db';
    database = NearSendDatabase.open(path: dbPath);
    tasks = ChunkRepository(database);
    transfers = TransferRepository(database);
    clock = 1000;
    registry = openRegistry();
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

    test('a page written through the registry is what the next read sees', () {
      // The pages of one transfer arrive across many requests. Under the in-memory registry
      // this was free; now it is the property that has to hold, so it is asserted on the rows
      // rather than on an object identity.
      register(transferId, manifestDigest: digest);
      expect(
        registry.addPage(transferId, pageFor(transferId, digest)),
        PageAcceptance.stored,
      );

      expect(registry.stagingFor(transferId).stagedFileCount, 1);
      expect(registry.store.stagedFileCount(transferId), 1);
      expect(registry.retainedEntryCount, 1);
    });

    test('an identical re-sent page is accepted without adding a row', () {
      // §6: "重传相同页返回成功". A client whose response was lost cannot tell the two
      // outcomes apart, so both answer success - and index-keyed storage is what keeps the
      // second from inflating the count.
      register(transferId, manifestDigest: digest);
      registry.addPage(transferId, pageFor(transferId, digest));

      expect(
        registry.addPage(transferId, pageFor(transferId, digest)),
        PageAcceptance.alreadyStored,
      );
      expect(registry.store.stagedFileCount(transferId), 1);
    });

    test('an overlapping page whose content differs is refused', () {
      // §6 rejects "重叠区间内容不一致"; keying by index makes this a per-row comparison
      // rather than a range comparison, so a retransmission that merely redraws the page
      // boundary still agrees.
      register(transferId, manifestDigest: digest);
      registry.addPage(transferId, pageFor(transferId, digest));

      expect(
        () => registry.addPage(transferId, pageFor(otherTransferId, digest)),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.manifestMismatch,
          ),
        ),
      );
      expect(
        registry.store.stagedFileCount(transferId),
        1,
        reason: 'the refused page must not have replaced the stored entry',
      );
    });

    test('two transfers have independent staging', () {
      register(transferId, manifestDigest: digest);
      register(otherTransferId, manifestDigest: digest);

      registry.addPage(transferId, pageFor(transferId, digest));
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

  group('surviving a restart (ADR-0004)', () {
    test('an unsealed proposal continues to accept pages after a reopen', () {
      register(transferId, manifestDigest: digest);
      registry.addPage(transferId, pageFor(transferId, digest));

      // A real restart: the first connection is closed and a second one opens the same file.
      // The registry is rebuilt from the database alone, with no in-memory carry-over.
      database.close();
      database = NearSendDatabase.open(path: dbPath);
      transfers = TransferRepository(database);
      registry = openRegistry();

      expect(
        registry.stagingFor(transferId).stagedFileCount,
        1,
        reason: 'the page is a row, so a restart costs the client nothing',
      );

      final ManifestChunkPage chunks = ManifestPager.chunkPages(
        manifestDigest: digest,
        fileId: files.single.fileId,
        chunks: chunksFor(files.single.sizeBytes),
      ).single;
      expect(registry.addPage(transferId, chunks), PageAcceptance.stored);

      final FrozenManifest frozen = registry.seal(transferId);
      expect(frozen.manifestDigest, digest);
      expect(frozen.fileCount, 1);
    });

    test('a sealed manifest is readable after a reopen', () {
      register(transferId, manifestDigest: digest);
      for (final ManifestPage page in fullManifest(transferId, files)) {
        registry.addPage(transferId, page);
      }
      final FrozenManifest before = registry.seal(transferId);

      database.close();
      database = NearSendDatabase.open(path: dbPath);
      transfers = TransferRepository(database);
      registry = openRegistry();

      final FrozenManifest? after = registry.frozenManifest(transferId);
      expect(
        after,
        isNotNull,
        reason:
            'decision, chunk verification and resume all read the frozen manifest, so a '
            'restart must not take it away',
      );
      expect(after!.manifestDigest, before.manifestDigest);
      expect(after.files.single.fileId, before.files.single.fileId);
      expect(after.toJson(), before.toJson());
    });

    test('the frozen manifest is stored as JSON, not only as pages', () {
      // Stated as a storage fact because it is what lets the store answer without rebuilding
      // an accumulator: a build that only kept pages would have to materialise the whole
      // manifest on every read.
      register(transferId, manifestDigest: digest);
      for (final ManifestPage page in fullManifest(transferId, files)) {
        registry.addPage(transferId, page);
      }
      registry.seal(transferId);

      final rows = database.db.select(
        'SELECT ${StorageSchema.sealedManifestColumn} AS body FROM '
        '${StorageSchema.manifestStagingTable} WHERE transfer_id = ?;',
        <Object?>[transferId],
      );
      expect(rows, hasLength(1));
      expect(rows.first['body'], isA<String>());
      expect(
        rows.first['body'] as String,
        contains(files.single.fileId),
        reason:
            'the stored body is the frozen manifest itself, so a read does not have to '
            'rebuild an accumulator from the pages',
      );
    });

    test('the window start survives a restart', () {
      // Otherwise a proposal that had been sitting for twenty-nine minutes would get a fresh
      // thirty every time the process bounced, and §6's bound would not bound anything.
      register(transferId, manifestDigest: digest);
      registry.addPage(transferId, pageFor(transferId, digest));

      database.close();
      database = NearSendDatabase.open(path: dbPath);
      transfers = TransferRepository(database);
      registry = openRegistry();

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
      );
    });

    test(
      'sealing writes the frozen manifest and the task state accessibly',
      () {
        // §6's seal is "a conclusion about what arrived"; the pages must stay available to a
        // restarting build for chunk verification, and §7's manifest read must still page them.
        register(transferId, manifestDigest: digest);
        for (final ManifestPage page in fullManifest(transferId, files)) {
          registry.addPage(transferId, page);
        }
        registry.seal(transferId);

        database.close();
        database = NearSendDatabase.open(path: dbPath);
        transfers = TransferRepository(database);
        registry = openRegistry();

        expect(registry.store.stagedFileCount(transferId), 1);
        expect(registry.store.stagedChunkCount(transferId), 1);
        expect(
          registry.store
              .readFilePage(transferId, startIndex: 0, limit: 128)
              .single
              .fileId,
          files.single.fileId,
        );
      },
    );
  });

  group("§6's thirty-minute window", () {
    test('a proposal is usable inside the window', () {
      register(transferId, manifestDigest: digest);
      registry.addPage(transferId, pageFor(transferId, digest));

      clock += ProtocolLimits.stagingTimeoutSeconds * 1000 - 1;
      expect(registry.stagingFor(transferId).stagedFileCount, 1);
    });

    test('a proposal past the window is TASK_EXPIRED and released', () {
      register(transferId, manifestDigest: digest);
      registry.addPage(transferId, pageFor(transferId, digest));

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
        reason: 'the refused proposal was released rather than left open',
      );
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
            'an expired proposal must not reopen on the next request, which is why expiry '
            'marks the row instead of deleting it',
      );
      expect(
        registry.store.readRecord(transferId)!.releasedAtMillis,
        isNotNull,
        reason:
            'the lifecycle timeline is persisted, so a release can be told from a proposal '
            'that was never started',
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
      for (final ManifestPage page in fullManifest(transferId, files)) {
        registry.addPage(transferId, page);
      }
      expect(registry.seal(transferId).manifestDigest, digest);

      clock += ProtocolLimits.stagingTimeoutSeconds * 1000 * 10;
      expect(
        registry.stagingFor(transferId).isSealed,
        isTrue,
        reason: 'a frozen manifest is a conclusion, not an unfinished proposal',
      );
      expect(registry.sealedTransferCount, 1);
      expect(
        registry.store.stagedChunkCount(transferId),
        1,
        reason: 'cleanup must not touch a frozen manifest pages either',
      );
    });

    test('discard forgets an unsealed transfer', () {
      register(transferId, manifestDigest: digest);
      registry.stagingFor(transferId);
      expect(registry.stagedTransferCount, 1);

      registry.discard(transferId);
      expect(registry.stagedTransferCount, 0);
      expect(registry.sealedTransferCount, 0);
      expect(registry.retainedEntryCount, 0);
    });

    test('a sealed manifest refuses to be discarded', () {
      // Its files are the task of record; deleting them would make the transfer
      // unverifiable, which is worse than the storage it saves.
      register(transferId, manifestDigest: digest);
      for (final ManifestPage page in fullManifest(transferId, files)) {
        registry.addPage(transferId, page);
      }
      registry.seal(transferId);

      expect(
        () => registry.discard(transferId),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.invalidState,
          ),
        ),
      );
      expect(registry.store.stagedFileCount(transferId), 1);
    });
  });

  group('release and lifecycle', () {
    test('a released unsealed proposal is no longer usable', () {
      register(transferId, manifestDigest: digest);
      registry.addPage(transferId, pageFor(transferId, digest));

      registry.release(transferId, StagingReleaseReason.cancelled);

      expect(
        () => registry.addPage(transferId, pageFor(transferId, digest)),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.taskExpired,
          ),
        ),
      );
      expect(registry.stagedTransferCount, 0);
    });

    test('a sealed proposal stays readable after release', () {
      // This is the shape the seal endpoint produces: freeze, then stop counting it against
      // the open-proposal budget. The manifest has to outlive the release.
      register(transferId, manifestDigest: digest);
      for (final ManifestPage page in fullManifest(transferId, files)) {
        registry.addPage(transferId, page);
      }
      registry.seal(transferId);
      registry.release(transferId, StagingReleaseReason.sealed);

      expect(registry.stagedTransferCount, 0);
      expect(registry.frozenManifest(transferId), isNotNull);
      expect(registry.stagingFor(transferId).isSealed, isTrue);
    });

    test(
      'a second seal returns the stored manifest rather than changing it',
      () {
        // §6 makes a seal a conclusion; repeating it must be a no-op, which is also what lets a
        // retry after a failed transaction finish instead of finding an unsealable manifest.
        register(transferId, manifestDigest: digest);
        for (final ManifestPage page in fullManifest(transferId, files)) {
          registry.addPage(transferId, page);
        }
        final FrozenManifest first = registry.seal(transferId);
        clock += 5000;
        final FrozenManifest second = registry.seal(transferId);

        expect(second.toJson(), first.toJson());
        expect(
          registry.store.readRecord(transferId)!.sealedAtMillis,
          lessThan(clock),
          reason: 'the second call must not restamp the seal',
        );
      },
    );

    test('a page written after the seal is refused', () {
      register(transferId, manifestDigest: digest);
      for (final ManifestPage page in fullManifest(transferId, files)) {
        registry.addPage(transferId, page);
      }
      registry.seal(transferId);

      expect(
        () => registry.addPage(transferId, pageFor(transferId, digest)),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.invalidState,
          ),
        ),
      );
    });

    test('a page whose digest disagrees with the transfer is refused', () {
      register(transferId, manifestDigest: digest);
      final String otherDigest = FrozenManifest(
        protocolMajor: ProtocolLimits.protocolMajor,
        protocolMinor: ProtocolLimits.protocolMinor,
        transferId: transferId,
        files: <ManifestFile>[file(3, 4)],
      ).manifestDigest;

      expect(
        () => registry.addPage(transferId, pageFor(transferId, otherDigest)),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.manifestMismatch,
          ),
        ),
      );
    });
  });

  group('bounded staging', () {
    test('refuses the next proposal at the configured concurrency limit', () {
      register(transferId, manifestDigest: digest);
      register(otherTransferId, manifestDigest: digest);
      final ManifestStagingRegistry bounded = openRegistry(
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
        final ManifestStagingRegistry bounded = openRegistry(
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
        final ManifestStagingRegistry bounded = openRegistry(
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
        expect(
          bounded.retainedEntryCount,
          0,
          reason:
              'the page that crossed the budget is discarded with the proposal, so the '
              'refusal is not itself the way to grow storage',
        );
      },
    );

    test('the budget counts rows in the database, not a process counter', () {
      register(transferId, manifestDigest: digest);
      registry.addPage(transferId, pageFor(transferId, digest));
      expect(registry.retainedEntryCount, registry.store.retainedRecordCount());

      database.close();
      database = NearSendDatabase.open(path: dbPath);
      transfers = TransferRepository(database);
      registry = openRegistry();

      expect(
        registry.retainedEntryCount,
        1,
        reason: 'a restarted process must still see what is retained',
      );
    });
  });
}
