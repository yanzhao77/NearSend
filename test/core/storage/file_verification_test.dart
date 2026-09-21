import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/file_verification.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_failure.dart';

/// Whole-file verification against the frozen manifest.
///
/// Two promises are under test. The file that was received is the file that was sent, and
/// a block whose bytes are wrong is demoted rather than trusted. The second one matters
/// more than it looks: protocol §5 allows `committedBytes` to fall precisely because a
/// committed block that is wrong would be trusted by every later resume.
void main() {
  late Directory dir;
  late NearSendDatabase database;
  late ChunkRepository chunks;
  late _FakeStaging staging;

  const String taskId = '00000000-0000-4000-8000-0000000000c1';
  const String fileId = '00000000-0000-4000-8000-0000000000f1';
  const int chunkSize = 4;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nearsend-verify-');
    database = NearSendDatabase.open(
      path: '${dir.path}${Platform.pathSeparator}verify.db',
    );
    chunks = ChunkRepository(database);
    staging = _FakeStaging();
    chunks.registerTask(
      taskId: taskId,
      role: 'receiver',
      direction: 'client_to_server',
      state: TransferState.ready,
      protocolMajor: 1,
      protocolMinor: 0,
    );
  });

  tearDown(() {
    database.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  FileVerifier verifier({bool demote = true}) =>
      FileVerifier(database, reader: staging);

  List<ChunkRecord> manifestFor(Uint8List bytes) => <ChunkRecord>[
    for (int i = 0; i < (bytes.length + chunkSize - 1) ~/ chunkSize; i++)
      ChunkRecord(
        index: i,
        length: (bytes.length - i * chunkSize) < chunkSize
            ? bytes.length - i * chunkSize
            : chunkSize,
        sha256: sha256
            .convert(
              bytes.sublist(
                i * chunkSize,
                (i + 1) * chunkSize > bytes.length
                    ? bytes.length
                    : (i + 1) * chunkSize,
              ),
            )
            .toString(),
      ),
  ];

  /// Registers [body] and commits every chunk, staging the same bytes.
  Future<void> receive(String body, {String id = fileId}) async {
    final Uint8List bytes = Uint8List.fromList(body.codeUnits);
    final List<ChunkRecord> manifest = manifestFor(bytes);
    chunks.registerFile(
      FrozenFileRegistration(
        taskId: taskId,
        fileId: id,
        relativePath: 'sample.bin',
        sizeBytes: bytes.length,
        fileSha256: sha256.convert(bytes).toString(),
        chunkManifestDigest: ChunkManifestCodec.digest(
          chunks: manifest,
          sizeBytes: bytes.length,
          chunkSizeBytes: chunkSize,
        ),
        chunks: manifest,
        chunkSizeBytes: chunkSize,
      ),
    );
    final int epoch = chunks.revokeAndAdvanceLease(taskId);
    for (int i = 0; i < manifest.length; i++) {
      final int start = i * chunkSize;
      final int end = (i + 1) * chunkSize > bytes.length
          ? bytes.length
          : (i + 1) * chunkSize;
      final Uint8List part = Uint8List.sublistView(bytes, start, end);
      await chunks.commitChunkAfterSync(
        taskId: taskId,
        fileId: id,
        index: i,
        bytes: part,
        leaseEpoch: epoch,
        sink: _Sink(),
      );
      staging.put(id, i, part);
    }
  }

  String chunkState(int index) =>
      database.db.select(
            'SELECT state FROM chunks WHERE file_id = ? AND idx = ?;',
            <Object?>[fileId, index],
          ).first['state']
          as String;

  group('an intact file', () {
    test('verifies and is exportable', () async {
      await receive('abcdefghijkl'); // three chunks

      final FileVerificationResult result = await verifier().verifyFile(
        fileId: fileId,
      );

      expect(result.isComplete, isTrue);
      expect(result.wholeFileDigestMatches, isTrue);
      expect(result.isExportable, isTrue);
      expect(result.damagedChunkIndices, isEmpty);
      expect(result.missingChunkIndices, isEmpty);
      expect(result.verifiedBytes, 12);
      expect(result.expectedBytes, 12);
      expect(result.summary, contains('verified'));
    });

    test(
      'the streamed digest equals the digest of the concatenated bytes',
      () async {
        const String body = 'abcdefghijkl';
        await receive(body);

        final FileVerificationResult result = await verifier().verifyFile(
          fileId: fileId,
        );

        expect(
          result.computedFileSha256,
          sha256.convert(body.codeUnits).toString(),
          reason:
              'the whole-file digest must be over exactly the concatenation the sender '
              'hashed; hashing each chunk separately and combining them would not be',
        );
      },
    );

    test('chunks are read in ascending order', () async {
      await receive('abcdefghijkl');

      await verifier().verifyFile(fileId: fileId);

      expect(
        staging.reads,
        <int>[0, 1, 2],
        reason:
            'order is what makes the running whole-file digest meaningful, so a reader '
            'asked out of order would be a correctness bug, not a performance one',
      );
    });

    test('a zero-byte file verifies against the empty digest', () async {
      await receive('');

      final FileVerificationResult result = await verifier().verifyFile(
        fileId: fileId,
      );

      expect(result.expectedBytes, 0);
      expect(result.verifiedBytes, 0);
      expect(result.computedFileSha256, sha256.convert(<int>[]).toString());
      expect(result.isExportable, isTrue);
    });

    test('bytes split across stream pieces still hash correctly', () async {
      // The fake reader emits 3-byte pieces, so a 4-byte chunk arrives split. This is the
      // case where an implementation that assumed one buffer per chunk would break.
      await receive('abcd');
      expect(
        staging.pieceSize,
        3,
        reason:
            'the test is only meaningful if pieces are smaller than a chunk',
      );

      final FileVerificationResult result = await verifier().verifyFile(
        fileId: fileId,
      );
      expect(result.isExportable, isTrue);
    });
  });

  group('damage is detected and demoted', () {
    test('a corrupted chunk is listed and returned to missing', () async {
      await receive('abcdefghijkl');
      staging.corrupt(fileId, 1);

      final FileVerificationResult result = await verifier().verifyFile(
        fileId: fileId,
      );

      expect(result.damagedChunkIndices, <int>[1]);
      expect(result.isComplete, isFalse);
      expect(result.isExportable, isFalse);
      expect(
        chunkState(1),
        'missing',
        reason:
            'a committed block whose bytes are wrong would be trusted by every later '
            'resume, so it must be demoted by the one component that can prove it',
      );
      expect(
        chunkState(0),
        'committed',
        reason: 'a damaged neighbour says nothing about this block',
      );
      expect(chunkState(2), 'committed');
    });

    test('a truncated chunk is damage', () async {
      await receive('abcdefgh');
      staging.truncate(fileId, 0, 2);

      final FileVerificationResult result = await verifier().verifyFile(
        fileId: fileId,
      );

      expect(result.damagedChunkIndices, <int>[0]);
      expect(chunkState(0), 'missing');
    });

    test('an over-long chunk is damage', () async {
      await receive('abcdefgh');
      staging.extend(fileId, 0);

      final FileVerificationResult result = await verifier().verifyFile(
        fileId: fileId,
      );

      expect(result.damagedChunkIndices, <int>[
        0,
      ], reason: 'a longer read is not more correct than a shorter one');
    });

    test(
      'several damaged chunks are all demoted, in ascending order',
      () async {
        await receive('abcdefghijkl');
        staging.corrupt(fileId, 2);
        staging.corrupt(fileId, 0);

        final FileVerificationResult result = await verifier().verifyFile(
          fileId: fileId,
        );

        expect(result.damagedChunkIndices, <int>[0, 2]);
        expect(chunkState(0), 'missing');
        expect(chunkState(2), 'missing');
        expect(chunkState(1), 'committed');
      },
    );

    test(
      'a chunk with no staged content is damage, not an empty chunk',
      () async {
        await receive('abcd');
        staging.remove(fileId, 0);

        final FileVerificationResult result = await verifier().verifyFile(
          fileId: fileId,
        );

        expect(result.damagedChunkIndices, <int>[0]);
        expect(
          result.missingChunkIndices,
          isEmpty,
          reason:
              'the chunk is still committed; it is the staged bytes that are gone, and the '
              'two cases lead to different repairs',
        );
      },
    );

    test(
      'the whole-file digest is not claimed when a chunk was damaged',
      () async {
        await receive('abcdefghijkl');
        staging.corrupt(fileId, 1);

        final FileVerificationResult result = await verifier().verifyFile(
          fileId: fileId,
        );

        expect(
          result.wholeFileDigestMatches,
          isNull,
          reason:
              'null means "not computed"; reporting false would imply a comparison that '
              'cannot honestly be made over data known to be wrong',
        );
        expect(
          result.isExportable,
          isFalse,
          reason: 'null must block export exactly as false does',
        );
      },
    );

    test('a dry run finds the damage without changing anything', () async {
      await receive('abcdefghijkl');
      staging.corrupt(fileId, 1);

      final FileVerificationResult result = await verifier().verifyFile(
        fileId: fileId,
        demoteDamagedChunks: false,
      );

      expect(result.damagedChunkIndices, <int>[1]);
      expect(
        chunkState(1),
        'committed',
        reason:
            'the user is shown "正在检查已接收内容" before anything is written, and a '
            'diagnostics view must be able to look without repairing',
      );
    });
  });

  group('incomplete files', () {
    test('a chunk that was never committed is reported as missing', () async {
      await receive('abcdefgh');
      // Model a block that has not arrived yet.
      chunks.markChunksMissing(fileId, <int>[1]);

      final FileVerificationResult result = await verifier().verifyFile(
        fileId: fileId,
      );

      expect(result.missingChunkIndices, <int>[1]);
      expect(
        result.damagedChunkIndices,
        isEmpty,
        reason:
            'a block that is not there is not evidence of corruption, and the repair is '
            'the same transfer either way only if we do not confuse the two',
      );
      expect(result.wholeFileDigestMatches, isNull);
      expect(result.isExportable, isFalse);
    });

    test(
      'the missing set does not stop the committed blocks being checked',
      () async {
        await receive('abcdefghijkl');
        chunks.markChunksMissing(fileId, <int>[1]);
        staging.corrupt(fileId, 2);

        final FileVerificationResult result = await verifier().verifyFile(
          fileId: fileId,
        );

        expect(result.missingChunkIndices, <int>[1]);
        expect(result.damagedChunkIndices, <int>[2]);
        expect(chunkState(2), 'missing');
        expect(chunkState(0), 'committed');
      },
    );
  });

  group('the export gate', () {
    test(
      'a whole-file mismatch blocks export even when every block is intact',
      () async {
        await receive('abcdefgh');
        // The blocks are all correct; the file-level digest the manifest froze is not. Only
        // the whole-file check can catch this, which is why §7 gates export on the digest.
        database.db.execute(
          'UPDATE files SET file_sha256 = ? WHERE file_id = ?;',
          <Object?>['0' * 64, fileId],
        );

        final FileVerificationResult result = await verifier().verifyFile(
          fileId: fileId,
        );

        expect(result.isComplete, isTrue);
        expect(result.wholeFileDigestMatches, isFalse);
        expect(result.isExportable, isFalse);
        expect(result.summary, contains('whole-file digest'));
      },
    );

    test(
      'a damaged file is no longer fully committed, so export refuses it',
      () async {
        // The cross-module property that makes "假完成" impossible: verification demotes the
        // block, and the export guard independently refuses a file with an uncommitted
        // block. Neither component has to trust the other's word for it.
        await receive('abcdefgh');
        staging.corrupt(fileId, 0);
        await verifier().verifyFile(fileId: fileId);

        expect(chunks.isFullyCommitted(fileId), isFalse);
        expect(chunks.missingChunkIndices(fileId), <int>[0]);
      },
    );

    test(
      'an intact file is still fully committed after verification',
      () async {
        await receive('abcdefgh');

        final FileVerificationResult result = await verifier().verifyFile(
          fileId: fileId,
        );

        expect(result.isExportable, isTrue);
        expect(
          chunks.isFullyCommitted(fileId),
          isTrue,
          reason: 'a check that always demoted something would be useless',
        );
      },
    );
  });

  group('manifest consistency', () {
    test('an unregistered file is refused', () async {
      await expectLater(
        verifier().verifyFile(fileId: fileId),
        throwsA(
          isA<StorageException>().having(
            (StorageException e) => e.code,
            'code',
            StorageFailureCode.manifestMismatch,
          ),
        ),
      );
    });

    test(
      'a chunk row count that disagrees with the manifest is refused',
      () async {
        await receive('abcdefgh');
        database.db.execute(
          'DELETE FROM chunks WHERE file_id = ? AND idx = 1;',
          <Object?>[fileId],
        );

        await expectLater(
          verifier().verifyFile(fileId: fileId),
          throwsA(isA<StorageException>()),
        );
      },
    );

    test(
      'chunk lengths that do not sum to the file size are refused',
      () async {
        await receive('abcdefgh');
        database.db.execute(
          'UPDATE files SET size_bytes = 99 WHERE file_id = ?;',
          <Object?>[fileId],
        );

        await expectLater(
          verifier().verifyFile(fileId: fileId),
          throwsA(isA<StorageException>()),
        );
      },
    );

    test(
      'verification never blames the staged bytes for a broken manifest',
      () async {
        await receive('abcdefgh');
        database.db.execute(
          'UPDATE files SET size_bytes = 99 WHERE file_id = ?;',
          <Object?>[fileId],
        );

        await expectLater(
          verifier().verifyFile(fileId: fileId),
          throwsA(isA<StorageException>()),
        );
        expect(
          chunkState(0),
          'committed',
          reason: 'a refused verification must not have demoted anything on its way out',
        );
      },
    );
  });

  group('more than one file', () {
    test('verification is per file and does not touch its neighbour', () async {
      const String otherId = '00000000-0000-4000-8000-0000000000f2';
      await receive('abcdefgh');
      await receive('wxyz', id: otherId);
      staging.corrupt(fileId, 0);

      final FileVerificationResult first = await verifier().verifyFile(
        fileId: fileId,
      );
      final FileVerificationResult second = await verifier().verifyFile(
        fileId: otherId,
      );

      expect(first.isExportable, isFalse);
      expect(second.isExportable, isTrue);
      expect(
        database.db.select(
          'SELECT state FROM chunks WHERE file_id = ? AND idx = 0;',
          <Object?>[otherId],
        ).first['state'],
        'committed',
      );
    });
  });
}

/// Serves staged bytes from memory, in pieces smaller than a chunk.
class _FakeStaging implements StagedChunkReader {
  final Map<String, Uint8List> _bytes = <String, Uint8List>{};

  /// Chunks asked for, in the order they were asked for.
  final List<int> reads = <int>[];

  /// Deliberately smaller than the 4-byte chunks the tests use, so a chunk always arrives
  /// split across pieces.
  final int pieceSize = 3;

  void put(String fileId, int index, Uint8List bytes) {
    _bytes['$fileId#$index'] = Uint8List.fromList(bytes);
  }

  void remove(String fileId, int index) => _bytes.remove('$fileId#$index');

  /// Flips bytes without changing the length, so only the digest can catch it.
  void corrupt(String fileId, int index) {
    final Uint8List? bytes = _bytes['$fileId#$index'];
    if (bytes == null || bytes.isEmpty) {
      throw StateError('nothing staged for $fileId#$index to corrupt');
    }
    bytes[0] = bytes[0] ^ 0xFF;
  }

  void truncate(String fileId, int index, int newLength) {
    final Uint8List? bytes = _bytes['$fileId#$index'];
    if (bytes == null) {
      throw StateError('nothing staged for $fileId#$index to truncate');
    }
    _bytes['$fileId#$index'] = Uint8List.sublistView(bytes, 0, newLength);
  }

  void extend(String fileId, int index) {
    final Uint8List? bytes = _bytes['$fileId#$index'];
    if (bytes == null) {
      throw StateError('nothing staged for $fileId#$index to extend');
    }
    _bytes['$fileId#$index'] = Uint8List.fromList(<int>[...bytes, 0x00]);
  }

  @override
  Stream<Uint8List> read({required String fileId, required int index}) async* {
    reads.add(index);
    final Uint8List? bytes = _bytes['$fileId#$index'];
    if (bytes == null) {
      return;
    }
    for (int offset = 0; offset < bytes.length; offset += pieceSize) {
      final int end = offset + pieceSize > bytes.length
          ? bytes.length
          : offset + pieceSize;
      yield Uint8List.sublistView(bytes, offset, end);
    }
  }
}

/// Reports the digest of the bytes it was handed, without writing anything.
class _Sink implements DurableChunkSink {
  @override
  Future<DurableChunkWriteResult> writeVerifyAndSync({
    required String fileId,
    required int index,
    required int offsetBytes,
    required Uint8List bytes,
  }) async => DurableChunkWriteResult(
    lengthBytes: bytes.length,
    sha256: sha256.convert(bytes).toString(),
  );
}
