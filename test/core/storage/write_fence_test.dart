import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/commit_window.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_failure.dart';
import 'package:nearsend/core/storage/write_fence.dart';

/// §8's write fence.
///
/// Two properties carry the weight, and both are about *ordering* rather than about the
/// database, which is why they are tested here and not through the repository:
///
/// * a file has **one writer at a time**, so two writers cannot interleave their bytes into
///   one staging file - the database would still be consistent while the bytes it describes
///   were not the bytes the winner wrote;
/// * a generation is **refused before its writes are awaited**, so the wait can actually
///   end, and a write that was queued when the hand-over began never starts.
///
/// The last group drives §8's sequence through a real database, because the fence and the
/// repository are two halves of one guarantee and neither alone is enough.
void main() {
  const String taskId = '00000000-0000-4000-8000-0000000000a1';
  const String otherTask = '00000000-0000-4000-8000-0000000000a2';
  const String fileId = '00000000-0000-4000-8000-0000000000f1';

  group('one writer per file', () {
    test('two writes of the same file never overlap', () async {
      final WriteFence fence = WriteFence();
      final Completer<void> gate = Completer<void>();
      final List<String> log = <String>[];
      int concurrent = 0;
      int maxConcurrent = 0;

      Future<void> body(String name, {bool block = false}) async {
        concurrent++;
        if (concurrent > maxConcurrent) {
          maxConcurrent = concurrent;
        }
        log.add('$name-start');
        if (block) {
          await gate.future;
        }
        log.add('$name-end');
        concurrent--;
      }

      final Future<void> first = fence.withFileWrite<void>(
        taskId: taskId,
        fileId: fileId,
        leaseEpoch: 1,
        write: () => body('first', block: true),
      );
      await pumpEventQueue();
      expect(log, <String>['first-start']);

      final Future<void> second = fence.withFileWrite<void>(
        taskId: taskId,
        fileId: fileId,
        leaseEpoch: 1,
        write: () => body('second'),
      );
      await pumpEventQueue();
      expect(log, <String>[
        'first-start',
      ], reason: 'the second writer must wait for the file, not join it');

      gate.complete();
      await Future.wait(<Future<void>>[first, second]);

      expect(log, <String>[
        'first-start',
        'first-end',
        'second-start',
        'second-end',
      ]);
      expect(maxConcurrent, 1);
    });

    test('three writers take the file in the order they arrived', () async {
      final WriteFence fence = WriteFence();
      final List<String> log = <String>[];

      Future<void> body(String name) async {
        log.add('$name-start');
        await pumpEventQueue();
        log.add('$name-end');
      }

      await Future.wait(<Future<void>>[
        for (final String name in <String>['a', 'b', 'c'])
          fence.withFileWrite<void>(
            taskId: taskId,
            fileId: fileId,
            leaseEpoch: 1,
            write: () => body(name),
          ),
      ]);

      expect(log, <String>[
        'a-start',
        'a-end',
        'b-start',
        'b-end',
        'c-start',
        'c-end',
      ]);
    });

    test('different files are written concurrently', () async {
      // The serialisation is per file, not per task: §8 says "每文件串行写入". Making it
      // per task would serialise a 10,000-file transfer for no reason.
      final WriteFence fence = WriteFence();
      final Completer<void> gate = Completer<void>();
      final List<String> log = <String>[];
      int concurrent = 0;
      int maxConcurrent = 0;

      Future<void> body(String name, {bool block = false}) async {
        concurrent++;
        if (concurrent > maxConcurrent) {
          maxConcurrent = concurrent;
        }
        log.add('$name-start');
        if (block) {
          await gate.future;
        }
        log.add('$name-end');
        concurrent--;
      }

      final Future<void> first = fence.withFileWrite<void>(
        taskId: taskId,
        fileId: 'file-a',
        leaseEpoch: 1,
        write: () => body('a', block: true),
      );
      await pumpEventQueue();

      final Future<void> second = fence.withFileWrite<void>(
        taskId: taskId,
        fileId: 'file-b',
        leaseEpoch: 1,
        write: () => body('b'),
      );
      await second;

      expect(log, containsAllInOrder(<String>['a-start', 'b-start', 'b-end']));
      expect(maxConcurrent, 2);

      gate.complete();
      await first;
    });

    test('the file is handed on even when the write throws', () async {
      final WriteFence fence = WriteFence();

      await expectLater(
        fence.withFileWrite<void>(
          taskId: taskId,
          fileId: fileId,
          leaseEpoch: 1,
          write: () async => throw StateError('the sink failed'),
        ),
        throwsStateError,
      );

      expect(
        fence.busyFileCount,
        0,
        reason: 'a failed write must not keep the file locked',
      );
      expect(fence.inFlightWrites(taskId), 0);

      final String result = await fence.withFileWrite<String>(
        taskId: taskId,
        fileId: fileId,
        leaseEpoch: 1,
        write: () async => 'ok',
      );
      expect(result, 'ok');
    });

    test('a file can be written again after each writer releases it', () async {
      // The release runs in a `finally` and must actually hand the file on: a release that
      // did not would leave the file locked for the rest of the process.
      final WriteFence fence = WriteFence();
      for (int i = 0; i < 5; i++) {
        final int value = await fence.withFileWrite<int>(
          taskId: taskId,
          fileId: fileId,
          leaseEpoch: 1,
          write: () async => i,
        );
        expect(value, i);
      }
      expect(fence.busyFileCount, 0);
    });

    test(
      'the registry is bounded by files in flight, not by files written',
      () async {
        final WriteFence fence = WriteFence();
        for (int i = 0; i < 50; i++) {
          await fence.withFileWrite<void>(
            taskId: taskId,
            fileId: 'file-$i',
            leaseEpoch: 1,
            write: () async {},
          );
        }
        expect(
          fence.busyFileCount,
          0,
          reason:
              '§5 allows 10,000 files in one transfer; keeping a queue per file ever '
              'written would grow with that',
        );
      },
    );
  });

  group('refusing a generation before awaiting it', () {
    test('a write under an already revoked generation never runs', () async {
      final WriteFence fence = WriteFence();
      await fence.revokeAndDrain(taskId: taskId, leaseEpoch: 2);

      expect(fence.accepts(taskId: taskId, leaseEpoch: 2), isFalse);
      expect(
        fence.accepts(taskId: taskId, leaseEpoch: 3),
        isTrue,
        reason: 'the next generation is exactly what the hand-over is making room for',
      );

      bool ran = false;
      await expectLater(
        fence.withFileWrite<void>(
          taskId: taskId,
          fileId: fileId,
          leaseEpoch: 1,
          write: () async {
            ran = true;
          },
        ),
        throwsA(_staleLease),
      );
      expect(ran, isFalse);
    });

    test('a write queued when the hand-over begins never starts', () async {
      // This is the re-check after the queue, and it is the reason the first check is not
      // enough: a write can pass the check, wait behind another writer, and only then reach
      // the front - after a resume has taken over.
      final WriteFence fence = WriteFence();
      final Completer<void> gate = Completer<void>();
      bool queuedRan = false;

      final Future<void> holding = fence.withFileWrite<void>(
        taskId: taskId,
        fileId: fileId,
        leaseEpoch: 1,
        write: () => gate.future,
      );
      await pumpEventQueue();

      final Future<void> queued = fence.withFileWrite<void>(
        taskId: taskId,
        fileId: fileId,
        leaseEpoch: 1,
        write: () async {
          queuedRan = true;
        },
      );
      await pumpEventQueue();
      expect(
        fence.inFlightWrites(taskId),
        2,
        reason:
            'the queued writer is registered before it owns the file, so a drain waits '
            'for it too',
      );

      final Future<void> drain = fence.revokeAndDrain(
        taskId: taskId,
        leaseEpoch: 1,
      );
      await pumpEventQueue();

      gate.complete();
      await holding;
      await expectLater(queued, throwsA(_staleLease));
      expect(queuedRan, isFalse);
      await drain;
      expect(fence.inFlightWrites(taskId), 0);
    });

    test(
      'revocation is monotonic, so an older resume cannot reopen a generation',
      () async {
        final WriteFence fence = WriteFence();
        await fence.revokeAndDrain(taskId: taskId, leaseEpoch: 5);
        await fence.revokeAndDrain(taskId: taskId, leaseEpoch: 2);

        expect(fence.revokedThrough(taskId), 5);
        expect(
          fence.accepts(taskId: taskId, leaseEpoch: 3),
          isFalse,
          reason: 'a late request for generation 2 must not lower the bar to 2',
        );
      },
    );

    test('one task revocation does not affect another', () async {
      final WriteFence fence = WriteFence();
      await fence.revokeAndDrain(taskId: taskId, leaseEpoch: 1);

      expect(fence.accepts(taskId: taskId, leaseEpoch: 1), isFalse);
      expect(fence.accepts(taskId: otherTask, leaseEpoch: 1), isTrue);

      final String result = await fence.withFileWrite<String>(
        taskId: otherTask,
        fileId: fileId,
        leaseEpoch: 1,
        write: () async => 'ok',
      );
      expect(result, 'ok');
    });
  });

  group('draining', () {
    test('an idle task drains immediately', () async {
      final WriteFence fence = WriteFence();
      await fence.revokeAndDrain(taskId: taskId, leaseEpoch: 0);
      expect(fence.revokedThrough(taskId), 0);
    });

    test(
      'the drain waits for an in-flight write and does not report early',
      () async {
        final WriteFence fence = WriteFence();
        final Completer<void> gate = Completer<void>();
        bool drained = false;

        final Future<void> write = fence.withFileWrite<void>(
          taskId: taskId,
          fileId: fileId,
          leaseEpoch: 1,
          write: () => gate.future,
        );
        await pumpEventQueue();

        final Future<void> drain = fence
            .revokeAndDrain(taskId: taskId, leaseEpoch: 1)
            .then((_) => drained = true);
        await pumpEventQueue();

        expect(
          drained,
          isFalse,
          reason: '§8 waits for the old writes to stop before allocating a generation',
        );
        expect(
          fence.accepts(taskId: taskId, leaseEpoch: 1),
          isFalse,
          reason:
              'refusal happens first, or new work would start during the wait',
        );
        expect(fence.inFlightWrites(taskId), 1);

        gate.complete();
        await write;
        await drain;
        expect(drained, isTrue);
      },
    );

    test('two overlapping drains both finish', () async {
      final WriteFence fence = WriteFence();
      final Completer<void> gate = Completer<void>();

      final Future<void> write = fence.withFileWrite<void>(
        taskId: taskId,
        fileId: fileId,
        leaseEpoch: 1,
        write: () => gate.future,
      );
      await pumpEventQueue();

      final Future<void> first = fence.revokeAndDrain(
        taskId: taskId,
        leaseEpoch: 1,
      );
      final Future<void> second = fence.revokeAndDrain(
        taskId: taskId,
        leaseEpoch: 1,
      );
      await pumpEventQueue();

      gate.complete();
      await write;
      await Future.wait(<Future<void>>[first, second]);
    });

    test(
      'a timeout throws instead of reporting that the writes stopped',
      () async {
        // A caller that read a timeout as "the writes stopped" would allocate a generation
        // while an old write was still writing into the file.
        final WriteFence fence = WriteFence();
        final Completer<void> gate = Completer<void>();

        final Future<void> write = fence.withFileWrite<void>(
          taskId: taskId,
          fileId: fileId,
          leaseEpoch: 1,
          write: () => gate.future,
        );
        await pumpEventQueue();

        await expectLater(
          fence.revokeAndDrain(
            taskId: taskId,
            leaseEpoch: 1,
            timeout: const Duration(milliseconds: 20),
          ),
          throwsA(
            isA<StorageException>()
                .having(
                  (StorageException e) => e.code,
                  'code',
                  StorageFailureCode.staleLease,
                )
                .having(
                  (StorageException e) => e.detail,
                  'detail',
                  allOf(contains('writer(s)'), contains('generation 1')),
                ),
          ),
        );

        expect(
          fence.accepts(taskId: taskId, leaseEpoch: 1),
          isFalse,
          reason:
              'the generation stays revoked, so the resume can be retried and no new '
              'old-generation work starts while it is stuck',
        );
        expect(fence.inFlightWrites(taskId), 1);

        gate.complete();
        await write;
      },
    );

    test('forget clears the revocation and releases waiters', () async {
      final WriteFence fence = WriteFence();
      final Completer<void> gate = Completer<void>();

      final Future<void> write = fence.withFileWrite<void>(
        taskId: taskId,
        fileId: fileId,
        leaseEpoch: 1,
        write: () => gate.future,
      );
      await pumpEventQueue();
      final Future<void> drain = fence.revokeAndDrain(
        taskId: taskId,
        leaseEpoch: 1,
      );
      await pumpEventQueue();

      fence.forget(taskId);
      await drain;
      expect(fence.revokedThrough(taskId), isNull);
      expect(
        fence.accepts(taskId: taskId, leaseEpoch: 1),
        isTrue,
        reason: 'forget is for a discarded task, not for the resume path',
      );

      gate.complete();
      await write;
    });
  });

  group('diagnostics', () {
    test('describe what is being fenced', () {
      final WriteFence fence = WriteFence();
      expect(fence.toString(), contains('WriteFence'));
      expect(fence.inFlightWrites(taskId), 0);
      expect(fence.revokedThrough(taskId), isNull);
    });
  });

  /// §8's sequence end to end: revoke the old session, wait for its writes to stop, then -
  /// and only then - allocate the next generation.
  ///
  /// Driven through the real repository, because the fence cannot make a commit land or
  /// fail and the repository cannot make a writer wait: the guarantee is the two together.
  group('§8 resume hand-over with a real generation', () {
    late Directory dir;
    late NearSendDatabase database;
    late ChunkRepository repository;
    const String contents = 'abcdefgh'; // 8 bytes / 4 = 2 chunks

    setUp(() {
      dir = Directory.systemTemp.createTempSync('nearsend-fence-');
      database = NearSendDatabase.open(
        path: '${dir.path}${Platform.pathSeparator}fence.db',
      );
      repository = ChunkRepository(database);

      final Uint8List bytes = _bytes(contents);
      final List<ChunkRecord> chunks = <ChunkRecord>[
        ChunkRecord(index: 0, length: 4, sha256: _hex(_bytes('abcd'))),
        ChunkRecord(index: 1, length: 4, sha256: _hex(_bytes('efgh'))),
      ];
      repository.registerTask(
        taskId: taskId,
        role: 'receiver',
        direction: 'client_to_server',
        state: TransferState.ready,
        protocolMajor: 1,
        protocolMinor: 0,
      );
      repository.registerFile(
        FrozenFileRegistration(
          taskId: taskId,
          fileId: fileId,
          relativePath: 'sample.bin',
          sizeBytes: bytes.length,
          fileSha256: _hex(bytes),
          chunkManifestDigest: ChunkManifestCodec.digest(
            chunks: chunks,
            sizeBytes: bytes.length,
            chunkSizeBytes: 4,
          ),
          chunks: chunks,
          chunkSizeBytes: 4,
        ),
      );
    });

    tearDown(() {
      database.close();
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    Future<ChunkWriteOutcome> writeFirstChunk({
      required WriteFence fence,
      required int leaseEpoch,
      required DurableChunkSink sink,
    }) => fence.withFileWrite<ChunkWriteOutcome>(
      taskId: taskId,
      fileId: fileId,
      leaseEpoch: leaseEpoch,
      write: () => repository.writeChunkThroughWindow(
        taskId: taskId,
        fileId: fileId,
        index: 0,
        bytes: _bytes('abcd'),
        leaseEpoch: leaseEpoch,
        sink: sink,
        window: ChunkCommitWindow(policy: CommitWindowPolicy.immediate),
        nowMillis: 0,
        atBoundary: true,
      ),
    );

    test('the old write is waited for, and only then is the next generation allocated', () async {
      final int epoch = repository.revokeAndAdvanceLease(taskId);
      final WriteFence fence = WriteFence();
      final Completer<void> gate = Completer<void>();

      final Future<ChunkWriteOutcome> write = writeFirstChunk(
        fence: fence,
        leaseEpoch: epoch,
        sink: _GatedSink(gate.future),
      );
      await pumpEventQueue();
      expect(
        repository.leaseEpoch(taskId),
        epoch,
        reason: 'the generation has not moved yet',
      );

      bool drained = false;
      final Future<void> drain = fence
          .revokeAndDrain(taskId: taskId, leaseEpoch: epoch)
          .then((_) => drained = true);
      await pumpEventQueue();

      expect(drained, isFalse);
      expect(fence.accepts(taskId: taskId, leaseEpoch: epoch), isFalse);

      // A new request for the dying generation is refused immediately, even though the
      // old write is still running.
      await expectLater(
        fence.withFileWrite<void>(
          taskId: taskId,
          fileId: fileId,
          leaseEpoch: epoch,
          write: () async {},
        ),
        throwsA(_staleLease),
      );

      // The in-flight write is allowed to finish and commit under the old generation. That
      // is not a leak: §8's next step, "校验已有数据", is what makes it safe to keep.
      gate.complete();
      final ChunkWriteOutcome outcome = await write;
      expect(outcome.state, ChunkWriteState.committed);
      expect(repository.committedChunkCount(fileId), 1);

      await drain;
      expect(drained, isTrue);

      final int next = repository.revokeAndAdvanceLease(taskId);
      expect(next, epoch + 1);
      expect(fence.accepts(taskId: taskId, leaseEpoch: next), isTrue);
      expect(
        fence.accepts(taskId: taskId, leaseEpoch: epoch),
        isFalse,
        reason: 'the old generation stays refused after the hand-over',
      );

      // Both checks refuse the old generation: the fence before the write, the repository
      // before the commit.
      await expectLater(
        writeFirstChunk(
          fence: fence,
          leaseEpoch: epoch,
          sink: _GatedSink((Completer<void>()..complete()).future),
        ),
        throwsA(_staleLease),
      );
      await expectLater(
        repository.writeChunkThroughWindow(
          taskId: taskId,
          fileId: fileId,
          index: 1,
          bytes: _bytes('efgh'),
          leaseEpoch: epoch,
          sink: _GatedSink((Completer<void>()..complete()).future),
          window: ChunkCommitWindow(policy: CommitWindowPolicy.immediate),
          nowMillis: 0,
          atBoundary: true,
        ),
        throwsA(_staleLease),
      );
    });

    test(
      'two writers of one file do not interleave through the repository',
      () async {
        final int epoch = repository.revokeAndAdvanceLease(taskId);
        final WriteFence fence = WriteFence();
        final _ConcurrencySink sink = _ConcurrencySink();
        final List<int> committedSeenBySecond = <int>[];

        Future<void> writeChunk(
          int index,
          String body, {
          bool record = false,
        }) => fence.withFileWrite<void>(
          taskId: taskId,
          fileId: fileId,
          leaseEpoch: epoch,
          write: () async {
            if (record) {
              // Read the committed count from inside the file's write slot: if the first
              // write had been allowed to interleave, this would not yet see its commit.
              committedSeenBySecond.add(repository.committedChunkCount(fileId));
            }
            await repository.writeChunkThroughWindow(
              taskId: taskId,
              fileId: fileId,
              index: index,
              bytes: _bytes(body),
              leaseEpoch: epoch,
              sink: sink,
              window: ChunkCommitWindow(policy: CommitWindowPolicy.immediate),
              nowMillis: 0,
              atBoundary: true,
            );
          },
        );

        await Future.wait(<Future<void>>[
          writeChunk(0, 'abcd'),
          writeChunk(1, 'efgh', record: true),
        ]);

        expect(
          sink.maxConcurrent,
          1,
          reason: '§8 puts a file lock before any byte is written',
        );
        expect(
          committedSeenBySecond.single,
          1,
          reason: 'the second writer must only start once the first has committed its chunk',
        );
        expect(repository.isFullyCommitted(fileId), isTrue);
        expect(repository.checkpointSeq(taskId), 2);
      },
    );

    test('the fenced write takes the file lock, the inner one does not', () async {
      // The repository offers both layers on purpose, so the lock can be tested alone; this
      // asserts that the method endpoint code is told to call actually holds it.
      final int epoch = repository.revokeAndAdvanceLease(taskId);
      final _ConcurrencySink sink = _ConcurrencySink();
      final Completer<void> gate = Completer<void>();

      final Future<ChunkWriteOutcome> held = repository.writeChunkWithFileLock(
        taskId: taskId,
        fileId: fileId,
        index: 0,
        bytes: _bytes('abcd'),
        leaseEpoch: epoch,
        sink: _GatedSink(gate.future),
        window: ChunkCommitWindow(policy: CommitWindowPolicy.immediate),
        nowMillis: 0,
        atBoundary: true,
      );
      await pumpEventQueue();
      expect(repository.fence.inFlightWrites(taskId), 1);

      // A second writer of the same file must wait for the first to release it.
      bool secondRan = false;
      final Future<ChunkWriteOutcome> queued = repository
          .writeChunkWithFileLock(
            taskId: taskId,
            fileId: fileId,
            index: 1,
            bytes: _bytes('efgh'),
            leaseEpoch: epoch,
            sink: sink,
            window: ChunkCommitWindow(policy: CommitWindowPolicy.immediate),
            nowMillis: 0,
            atBoundary: true,
          )
          .then((ChunkWriteOutcome outcome) {
            secondRan = true;
            return outcome;
          });
      await pumpEventQueue();
      expect(secondRan, isFalse);

      gate.complete();
      await held;
      await queued;

      expect(
        sink.maxConcurrent,
        1,
        reason: 'the file lock is what keeps the two writes from overlapping',
      );
      expect(repository.isFullyCommitted(fileId), isTrue);
    });

    test(
      'revokeAndAdvanceLeaseAfterWritesStop cannot allocate early',
      () async {
        final int epoch = repository.revokeAndAdvanceLease(taskId);
        final Completer<void> gate = Completer<void>();

        final Future<ChunkWriteOutcome> write = repository
            .writeChunkWithFileLock(
              taskId: taskId,
              fileId: fileId,
              index: 0,
              bytes: _bytes('abcd'),
              leaseEpoch: epoch,
              sink: _GatedSink(gate.future),
              window: ChunkCommitWindow(policy: CommitWindowPolicy.immediate),
              nowMillis: 0,
              atBoundary: true,
            );
        await pumpEventQueue();

        int? allocated;
        final Future<void> handOver = repository
            .revokeAndAdvanceLeaseAfterWritesStop(
              taskId: taskId,
              currentLeaseEpoch: epoch,
            )
            .then((int value) => allocated = value);
        await pumpEventQueue();

        expect(
          allocated,
          isNull,
          reason:
              'allocating while the old write is still writing is the exact ordering §8 '
              'forbids',
        );
        expect(
          repository.leaseEpoch(taskId),
          epoch,
          reason: 'the generation must not move before the writes stop',
        );

        gate.complete();
        await write;
        await handOver;

        expect(allocated, epoch + 1);
        expect(repository.leaseEpoch(taskId), epoch + 1);
        expect(
          repository.fence.accepts(taskId: taskId, leaseEpoch: epoch),
          isFalse,
        );
        expect(
          repository.fence.accepts(taskId: taskId, leaseEpoch: epoch + 1),
          isTrue,
        );
      },
    );

    test(
      'a timed-out hand-over does not allocate the next generation',
      () async {
        final int epoch = repository.revokeAndAdvanceLease(taskId);
        final Completer<void> gate = Completer<void>();

        final Future<ChunkWriteOutcome> write = repository
            .writeChunkWithFileLock(
              taskId: taskId,
              fileId: fileId,
              index: 0,
              bytes: _bytes('abcd'),
              leaseEpoch: epoch,
              sink: _GatedSink(gate.future),
              window: ChunkCommitWindow(policy: CommitWindowPolicy.immediate),
              nowMillis: 0,
              atBoundary: true,
            );
        await pumpEventQueue();

        await expectLater(
          repository.revokeAndAdvanceLeaseAfterWritesStop(
            taskId: taskId,
            currentLeaseEpoch: epoch,
            timeout: const Duration(milliseconds: 20),
          ),
          throwsA(_staleLease),
        );
        expect(
          repository.leaseEpoch(taskId),
          epoch,
          reason:
              'a caller that read the timeout as "the writes stopped" would have moved the '
              'generation while a write was still in the file',
        );

        gate.complete();
        await write;
      },
    );
  });
}

final Matcher _staleLease = isA<StorageException>().having(
  (StorageException e) => e.code,
  'code',
  StorageFailureCode.staleLease,
);

Uint8List _bytes(String value) => Uint8List.fromList(value.codeUnits);

String _hex(List<int> bytes) => sha256.convert(bytes).toString();

/// A sink that blocks until released, so a write can be held inside its write window.
class _GatedSink implements DurableChunkSink {
  _GatedSink(this._gate);

  final Future<void> _gate;

  @override
  Future<DurableChunkWriteResult> writeVerifyAndSync({
    required String fileId,
    required int index,
    required int offsetBytes,
    required Uint8List bytes,
  }) async {
    await _gate;
    return DurableChunkWriteResult(
      lengthBytes: bytes.length,
      sha256: _hex(bytes),
    );
  }
}

/// A sink that records how many writes were inside it at once.
class _ConcurrencySink implements DurableChunkSink {
  int _concurrent = 0;
  int maxConcurrent = 0;

  @override
  Future<DurableChunkWriteResult> writeVerifyAndSync({
    required String fileId,
    required int index,
    required int offsetBytes,
    required Uint8List bytes,
  }) async {
    _concurrent++;
    if (_concurrent > maxConcurrent) {
      maxConcurrent = _concurrent;
    }
    // Yields, so an unserialised second writer would be observed inside the window.
    await pumpEventQueue();
    _concurrent--;
    return DurableChunkWriteResult(
      lengthBytes: bytes.length,
      sha256: _hex(bytes),
    );
  }
}
