import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_failure.dart';

/// The chunk repository's guarantees, including the crash windows the quality strategy
/// requires.
///
/// The single most important property under test is that **nothing is committed unless
/// the bytes were durably synced and matched the frozen manifest**. Every failure below
/// asserts the same consequence: the chunk stays `missing`, so it is re-sent rather than
/// trusted. A repository that acknowledged a chunk it had not committed would make
/// recovery silently lose data.
void main() {
  late Directory dir;
  late NearSendDatabase database;
  late ChunkRepository repository;
  late String databasePath;

  const String taskId = '00000000-0000-4000-8000-0000000000a1';
  const String fileId = '00000000-0000-4000-8000-0000000000f1';

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nearsend-chunks-');
    databasePath = '${dir.path}${Platform.pathSeparator}chunks.db';
    database = NearSendDatabase.open(path: databasePath);
    repository = ChunkRepository(database);
  });

  tearDown(() {
    database.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  /// Registers a task and a file whose chunks are described by real digests.
  ///
  /// A small chunk size is used so multi-chunk cases stay fast; the 4 MiB value is fixed
  /// by the manifest layer (T02-01) and is exercised separately below.
  FrozenFileRegistration registerFile({
    required String contents,
    int chunkSizeBytes = 4,
    String id = fileId,
  }) {
    final Uint8List bytes = Uint8List.fromList(contents.codeUnits);
    final int chunkCount = bytes.isEmpty
        ? 0
        : (bytes.length + chunkSizeBytes - 1) ~/ chunkSizeBytes;
    final List<ChunkRecord> chunks = <ChunkRecord>[
      for (int i = 0; i < chunkCount; i++)
        ChunkRecord(
          index: i,
          length: _chunkLength(bytes.length, chunkSizeBytes, i),
          sha256: _hex(
            bytes.sublist(
              i * chunkSizeBytes,
              (i * chunkSizeBytes + chunkSizeBytes) > bytes.length
                  ? bytes.length
                  : i * chunkSizeBytes + chunkSizeBytes,
            ),
          ),
        ),
    ];

    final FrozenFileRegistration registration = FrozenFileRegistration(
      taskId: taskId,
      fileId: id,
      relativePath: 'sample.bin',
      sizeBytes: bytes.length,
      fileSha256: _hex(bytes),
      chunkManifestDigest: ChunkManifestCodec.digest(
        chunks: chunks,
        sizeBytes: bytes.length,
        chunkSizeBytes: chunkSizeBytes,
      ),
      chunks: chunks,
      chunkSizeBytes: chunkSizeBytes,
    );

    repository.registerTask(
      taskId: taskId,
      role: 'receiver',
      direction: 'client_to_server',
      state: 'READY',
      protocolMajor: 1,
      protocolMinor: 0,
    );
    repository.registerFile(registration);
    return registration;
  }

  group('registration', () {
    test('every chunk starts missing and offsets come from the manifest', () {
      registerFile(contents: 'abcdefghij'); // 10 bytes, chunk size 4 → 3 chunks

      expect(repository.missingChunkIndices(fileId), <int>[0, 1, 2]);
      expect(repository.committedChunkCount(fileId), 0);
      expect(repository.isFullyCommitted(fileId), isFalse);

      // Offsets are derived, never taken from the caller: chunk 2 starts at 8.
      expect(repository.readChunk(fileId, 2).offsetBytes, 8);
      expect(repository.readChunk(fileId, 2).lengthBytes, 2);
      expect(repository.readChunk(fileId, 0).lengthBytes, 4);
    });

    test('a chunk manifest that disagrees with the size is refused', () {
      expect(
        () => registerFile(contents: 'abcdefghij').fileId.isNotEmpty
            ? null
            : null,
        returnsNormally,
      );

      final FrozenFileRegistration broken = FrozenFileRegistration(
        taskId: taskId,
        fileId: '00000000-0000-4000-8000-0000000000f2',
        relativePath: 'broken.bin',
        sizeBytes: 10,
        fileSha256: _hex(Uint8List(10)),
        chunkManifestDigest: _hex(Uint8List(32)),
        chunks: <ChunkRecord>[
          ChunkRecord(index: 0, length: 10, sha256: _hex(Uint8List(10))),
        ],
        chunkSizeBytes: 4,
      );
      expect(
        () => repository.registerFile(broken),
        throwsA(
          isA<StorageException>().having(
            (StorageException e) => e.code,
            'code',
            StorageFailureCode.manifestMismatch,
          ),
        ),
      );
    });

    test('a zero-byte file registers no chunks and is already complete', () {
      registerFile(contents: '');
      expect(repository.missingChunkIndices(fileId), isEmpty);
      expect(repository.isFullyCommitted(fileId), isTrue);
    });
  });

  group('commit requires a current write generation', () {
    test('committing with generation 0 is refused', () async {
      registerFile(contents: 'abcd');
      final _RecordingSink sink = _RecordingSink();

      await expectLater(
        repository.commitChunkAfterSync(
          taskId: taskId,
          fileId: fileId,
          index: 0,
          bytes: _bytes('abcd'),
          leaseEpoch: 0,
          sink: sink,
        ),
        throwsA(
          isA<StorageException>().having(
            (StorageException e) => e.code,
            'code',
            StorageFailureCode.staleLease,
          ),
        ),
      );
      expect(
        sink.calls,
        0,
        reason: 'the refusal must happen before any bytes are written',
      );
      expect(repository.missingChunkIndices(fileId), <int>[0]);
    });

    test('an old generation is refused after a resume advances it', () async {
      registerFile(contents: 'abcd');
      final int first = repository.revokeAndAdvanceLease(taskId);
      expect(first, 1);

      final int second = repository.revokeAndAdvanceLease(taskId);
      expect(second, 2);

      await expectLater(
        repository.commitChunkAfterSync(
          taskId: taskId,
          fileId: fileId,
          index: 0,
          bytes: _bytes('abcd'),
          leaseEpoch: first,
          sink: _RecordingSink(),
        ),
        throwsA(
          isA<StorageException>().having(
            (StorageException e) => e.code,
            'code',
            StorageFailureCode.staleLease,
          ),
        ),
      );
      expect(repository.missingChunkIndices(fileId), <int>[0]);
    });
  });

  group('the happy path', () {
    test(
      'a chunk is committed only after the sink reports a durable sync',
      () async {
        registerFile(contents: 'abcdefghij');
        final int epoch = repository.revokeAndAdvanceLease(taskId);
        final _RecordingSink sink = _RecordingSink();

        final StoredChunk stored = await repository.commitChunkAfterSync(
          taskId: taskId,
          fileId: fileId,
          index: 1,
          bytes: _bytes('efgh'),
          leaseEpoch: epoch,
          sink: sink,
        );

        expect(sink.calls, 1);
        expect(stored.state, ChunkState.committed);
        expect(repository.committedChunkCount(fileId), 1);
        expect(repository.missingChunkIndices(fileId), <int>[0, 2]);
        expect(repository.isFullyCommitted(fileId), isFalse);
      },
    );

    test('committing every chunk completes the file', () async {
      registerFile(contents: 'abcdefghij');
      final int epoch = repository.revokeAndAdvanceLease(taskId);

      for (final (int index, String part) in <(int, String)>[
        (0, 'abcd'),
        (1, 'efgh'),
        (2, 'ij'),
      ]) {
        await repository.commitChunkAfterSync(
          taskId: taskId,
          fileId: fileId,
          index: index,
          bytes: _bytes(part),
          leaseEpoch: epoch,
          sink: _RecordingSink(),
        );
      }

      expect(repository.isFullyCommitted(fileId), isTrue);
      expect(repository.missingChunkIndices(fileId), isEmpty);
    });
  });

  group('failure windows leave the chunk missing', () {
    test('a durable sync failure does not commit', () async {
      registerFile(contents: 'abcd');
      final int epoch = repository.revokeAndAdvanceLease(taskId);

      await expectLater(
        repository.commitChunkAfterSync(
          taskId: taskId,
          fileId: fileId,
          index: 0,
          bytes: _bytes('abcd'),
          leaseEpoch: epoch,
          sink: _RecordingSink(failWith: StateError('fsync failed')),
        ),
        throwsA(isA<Object>()),
      );
      expect(
        repository.readChunk(fileId, 0).state,
        ChunkState.missing,
        reason: 'a write that was never synced is not progress',
      );
    });

    test('a sink that writes the wrong bytes cannot cause a commit', () async {
      registerFile(contents: 'abcd');
      final int epoch = repository.revokeAndAdvanceLease(taskId);

      await expectLater(
        repository.commitChunkAfterSync(
          taskId: taskId,
          fileId: fileId,
          index: 0,
          bytes: _bytes('abcd'),
          leaseEpoch: epoch,
          sink: _RecordingSink(reportSha: _hex(_bytes('wxyz'))),
        ),
        throwsA(
          isA<StorageException>().having(
            (StorageException e) => e.code,
            'code',
            StorageFailureCode.syncReceiptMismatch,
          ),
        ),
      );
      expect(repository.readChunk(fileId, 0).state, ChunkState.missing);
    });

    test(
      'a sink that reports the wrong length cannot cause a commit',
      () async {
        registerFile(contents: 'abcd');
        final int epoch = repository.revokeAndAdvanceLease(taskId);

        await expectLater(
          repository.commitChunkAfterSync(
            taskId: taskId,
            fileId: fileId,
            index: 0,
            bytes: _bytes('abcd'),
            leaseEpoch: epoch,
            sink: _RecordingSink(reportLength: 3),
          ),
          throwsA(
            isA<StorageException>().having(
              (StorageException e) => e.code,
              'code',
              StorageFailureCode.syncReceiptMismatch,
            ),
          ),
        );
        expect(repository.readChunk(fileId, 0).state, ChunkState.missing);
      },
    );

    test(
      'bytes that do not match the frozen length are refused before writing',
      () async {
        registerFile(contents: 'abcdefghij');
        final int epoch = repository.revokeAndAdvanceLease(taskId);
        final _RecordingSink sink = _RecordingSink();

        await expectLater(
          repository.commitChunkAfterSync(
            taskId: taskId,
            fileId: fileId,
            index: 0,
            bytes: _bytes('abc'), // one byte short
            leaseEpoch: epoch,
            sink: sink,
          ),
          throwsA(
            isA<StorageException>().having(
              (StorageException e) => e.code,
              'code',
              StorageFailureCode.manifestMismatch,
            ),
          ),
        );
        expect(
          sink.calls,
          0,
          reason: 'the length check happens before the write',
        );
      },
    );

    test('a resume that lands mid-write prevents the commit', () async {
      // The fault window §8 warns about: checking the generation only at the request
      // entry point would let this write land after the resume took over.
      registerFile(contents: 'abcd');
      final int epoch = repository.revokeAndAdvanceLease(taskId);

      final _RecordingSink sink = _RecordingSink(
        beforeReturn: () => repository.revokeAndAdvanceLease(taskId),
      );

      await expectLater(
        repository.commitChunkAfterSync(
          taskId: taskId,
          fileId: fileId,
          index: 0,
          bytes: _bytes('abcd'),
          leaseEpoch: epoch,
          sink: sink,
        ),
        throwsA(
          isA<StorageException>().having(
            (StorageException e) => e.code,
            'code',
            StorageFailureCode.staleLease,
          ),
        ),
      );
      expect(
        repository.readChunk(fileId, 0).state,
        ChunkState.missing,
        reason: 'the superseded generation must not have committed anything',
      );
      expect(repository.leaseEpoch(taskId), 2);
    });

    test(
      'a chunk that disappears before the commit fails the commit',
      () async {
        registerFile(contents: 'abcd');
        final int epoch = repository.revokeAndAdvanceLease(taskId);

        final _RecordingSink sink = _RecordingSink(
          beforeReturn: () => database.db.execute(
            "DELETE FROM chunks WHERE file_id = '$fileId' AND idx = 0;",
          ),
        );

        await expectLater(
          repository.commitChunkAfterSync(
            taskId: taskId,
            fileId: fileId,
            index: 0,
            bytes: _bytes('abcd'),
            leaseEpoch: epoch,
            sink: sink,
          ),
          throwsA(isA<StorageException>()),
        );
      },
    );
  });

  group('committed chunks are the authority, and survive a restart', () {
    test('a committed chunk persists across close and reopen', () async {
      registerFile(contents: 'abcdefghij');
      final int epoch = repository.revokeAndAdvanceLease(taskId);
      await repository.commitChunkAfterSync(
        taskId: taskId,
        fileId: fileId,
        index: 0,
        bytes: _bytes('abcd'),
        leaseEpoch: epoch,
        sink: _RecordingSink(),
      );

      final String path = databasePath;
      database.close();

      // Reopen: this is the restart case. Nothing in memory carried over.
      database = NearSendDatabase.open(path: path);
      repository = ChunkRepository(database);

      expect(repository.committedChunkCount(fileId), 1);
      expect(repository.missingChunkIndices(fileId), <int>[1, 2]);
      expect(
        repository.leaseEpoch(taskId),
        epoch,
        reason:
            'the write generation is durable too, so an old writer stays stale',
      );
    });

    test('damaged committed chunks can be returned to missing', () async {
      registerFile(contents: 'abcdefghij');
      final int epoch = repository.revokeAndAdvanceLease(taskId);
      for (final (int index, String part) in <(int, String)>[
        (0, 'abcd'),
        (1, 'efgh'),
        (2, 'ij'),
      ]) {
        await repository.commitChunkAfterSync(
          taskId: taskId,
          fileId: fileId,
          index: index,
          bytes: _bytes(part),
          leaseEpoch: epoch,
          sink: _RecordingSink(),
        );
      }
      expect(repository.isFullyCommitted(fileId), isTrue);

      repository.markChunksMissing(fileId, <int>[1]);

      expect(
        repository.missingChunkIndices(fileId),
        <int>[1],
        reason:
            'a damaged committed chunk is worse than a missing one, because recovery '
            'would trust it; protocol §5 allows committed progress to fall for this',
      );
      expect(repository.isFullyCommitted(fileId), isFalse);
    });

    test('marking missing is a no-op for an empty list', () {
      registerFile(contents: 'abcd');
      expect(
        () => repository.markChunksMissing(fileId, const <int>[]),
        returnsNormally,
      );
    });
  });

  group('the real chunk size', () {
    test('a file just over 4 MiB registers exactly two chunks', () async {
      const int size = ProtocolLimits.chunkSizeBytes + 3;
      final Uint8List bytes = Uint8List(size);
      for (int i = 0; i < size; i++) {
        bytes[i] = i % 251;
      }

      final List<ChunkRecord> chunks = <ChunkRecord>[
        ChunkRecord(
          index: 0,
          length: ProtocolLimits.chunkSizeBytes,
          sha256: _hex(bytes.sublist(0, ProtocolLimits.chunkSizeBytes)),
        ),
        ChunkRecord(index: 1, length: 3, sha256: _hex(bytes.sublist(size - 3))),
      ];

      repository.registerTask(
        taskId: taskId,
        role: 'receiver',
        direction: 'client_to_server',
        state: 'READY',
        protocolMajor: 1,
        protocolMinor: 0,
      );
      repository.registerFile(
        FrozenFileRegistration(
          taskId: taskId,
          fileId: fileId,
          relativePath: 'big.bin',
          sizeBytes: size,
          fileSha256: _hex(bytes),
          chunkManifestDigest: ChunkManifestCodec.digest(
            chunks: chunks,
            sizeBytes: size,
            chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
          ),
          chunks: chunks,
        ),
      );

      expect(repository.missingChunkIndices(fileId), <int>[0, 1]);
      expect(
        repository.readChunk(fileId, 1).offsetBytes,
        ProtocolLimits.chunkSizeBytes,
        reason:
            'the tail chunk starts at the 4 MiB boundary, computed in 64-bit',
      );
      expect(repository.readChunk(fileId, 1).lengthBytes, 3);
    });
  });
}

/// A sink that records calls and can inject each failure the commit protocol must
/// survive.
class _RecordingSink implements DurableChunkSink {
  _RecordingSink({
    this.failWith,
    this.reportSha,
    this.reportLength,
    this.beforeReturn,
  });

  final Object? failWith;
  final String? reportSha;
  final int? reportLength;

  /// Runs after the "write" and before returning, to model something happening during
  /// the write window.
  final void Function()? beforeReturn;

  int calls = 0;

  @override
  Future<DurableChunkWriteResult> writeVerifyAndSync({
    required String fileId,
    required int index,
    required int offsetBytes,
    required Uint8List bytes,
  }) async {
    calls++;
    beforeReturn?.call();
    if (failWith != null) {
      throw failWith!;
    }
    return DurableChunkWriteResult(
      lengthBytes: reportLength ?? bytes.length,
      sha256: reportSha ?? _hex(bytes),
    );
  }
}

Uint8List _bytes(String value) => Uint8List.fromList(value.codeUnits);

int _chunkLength(int sizeBytes, int chunkSizeBytes, int index) {
  final int remaining = sizeBytes - index * chunkSizeBytes;
  return remaining < chunkSizeBytes ? remaining : chunkSizeBytes;
}

String _hex(List<int> bytes) => sha256.convert(bytes).toString();
