import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_failure.dart';

/// Storage failure injection for the `QUALITY_AND_ACCEPTANCE.md` §3 matrix rows
/// 「磁盘满」 and 「DB 提交失败」.
///
/// ## What the out-of-space injections actually are
///
/// The volume-full condition here is **produced by the SQLite engine**, not simulated:
/// `PRAGMA max_page_count` is pinned to the database's current page count and rows are
/// inserted until the engine refuses with result code 13, `SQLITE_FULL`
/// ("database or disk is full"). That is the same error a genuinely full volume
/// produces, and it is the only failure in this file that claims to be a real
/// disk-full condition.
///
/// ## What could not be injected, and why that is worth knowing
///
/// The commit that records a chunk is a single-row `UPDATE`, and a probe showed it
/// **succeeds even when the database is completely out of room**, because it rewrites an
/// existing row and allocates no new page. So page exhaustion cannot be used to make
/// `commitChunkAfterSync` fail at its own commit statement. In the real product the
/// bytes that fill a volume are the chunk data the sink writes, not the database row, so
/// «磁盘满」 is modelled at the sink (see the refusal group) and the database-side
/// condition is exercised through the transaction primitive.
void main() {
  late Directory dir;
  late NearSendDatabase database;
  late ChunkRepository chunks;

  const String taskId = '00000000-0000-4000-8000-0000000000c1';
  const String fileId = '00000000-0000-4000-8000-0000000000f1';
  const int chunkSize = 4;
  const String contents = 'abcdefgh'; // exactly two chunks

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nearsend-inject-');
    database = NearSendDatabase.open(
      path: '${dir.path}${Platform.pathSeparator}inject.db',
    );
    chunks = ChunkRepository(database);
    chunks.registerTask(
      taskId: taskId,
      role: 'receiver',
      direction: 'client_to_server',
      state: 'ready',
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

  void registerFile({String id = fileId, String body = contents}) {
    final Uint8List bytes = Uint8List.fromList(body.codeUnits);
    final int count = (bytes.length + chunkSize - 1) ~/ chunkSize;
    final List<ChunkRecord> manifest = <ChunkRecord>[
      for (int i = 0; i < count; i++)
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
  }

  Uint8List chunkBytes(int index) => Uint8List.sublistView(
    Uint8List.fromList(contents.codeUnits),
    index * chunkSize,
    (index + 1) * chunkSize,
  );

  int peerCount() =>
      database.db.select('SELECT COUNT(*) AS c FROM peers;').first['c'] as int;

  /// Pins the database at its current size so it cannot grow, and returns that size.
  int pinToCurrentSize() {
    final int pages =
        database.db.select('PRAGMA page_count;').first['page_count'] as int;
    database.db.execute('PRAGMA max_page_count = $pages;');
    return pages;
  }

  /// Inserts rows until the engine reports the volume is full.
  ///
  /// Returns how many rows were accepted and the refusal that stopped it. The database
  /// is left genuinely full: the refused transaction rolled back, so the last committed
  /// state is exactly at the limit.
  _Fill fillUntilFull() {
    int inserted = 0;
    Object? failure;
    for (int i = 0; i < 50000; i++) {
      try {
        database.transaction(() {
          database.db.execute(
            'INSERT INTO peers (peer_id, identity_fingerprint, authorized) '
            'VALUES (?, ?, 0);',
            <Object?>['fill-$i', 'f' * 64],
          );
        });
        inserted++;
      } on Object catch (error) {
        failure = error;
        break;
      }
    }
    return _Fill(inserted: inserted, failure: failure);
  }

  group('out of space', () {
    test(
      'a full volume is reported as exhaustion, not a retryable failure',
      () {
        pinToCurrentSize();
        final _Fill fill = fillUntilFull();

        expect(fill.failure, isA<StorageException>());
        final StorageException failure = fill.failure! as StorageException;
        expect(
          failure.code,
          StorageFailureCode.spaceInsufficient,
          reason:
              'reporting this as commitFailed would set retryable: true and let a client '
              'retry forever against a volume that cannot accept the write',
        );
        expect(failure.code.retryable, isFalse);
        expect(failure.code.protocolCode, ProtocolErrorCode.spaceInsufficient);
        expect(failure.code.protocolCode!.wireCode, 'SPACE_INSUFFICIENT');
        expect(
          failure.code.protocolCode!.httpStatus,
          507,
          reason: '§11 answers exhaustible space with 507, not 500',
        );

        final Object? cause = failure.cause;
        expect(cause, isA<SqliteException>());
        expect(
          (cause! as SqliteException).resultCode,
          13,
          reason: 'SQLITE_FULL, produced by the engine rather than simulated',
        );
      },
    );

    test('the refused write leaves no partial row behind', () {
      pinToCurrentSize();
      final _Fill fill = fillUntilFull();

      expect(fill.inserted, greaterThan(0));
      expect(
        peerCount(),
        fill.inserted,
        reason: 'the refused insert must have been rolled back whole',
      );
    });

    test('progress committed before the refusal survives it', () async {
      registerFile();
      final int epoch = chunks.revokeAndAdvanceLease(taskId);
      await chunks.commitChunkAfterSync(
        taskId: taskId,
        fileId: fileId,
        index: 0,
        bytes: chunkBytes(0),
        leaseEpoch: epoch,
        sink: _WorkingSink(),
      );
      expect(chunks.committedChunkCount(fileId), 1);

      pinToCurrentSize();
      expect(fillUntilFull().failure, isA<StorageException>());

      expect(
        chunks.committedChunkCount(fileId),
        1,
        reason:
            'a full volume must not cost the receiver its committed progress',
      );
      expect(chunks.missingChunkIndices(fileId), <int>[1]);
      expect(chunks.isFullyCommitted(fileId), isFalse);
    });

    test('a chunk commit caught by a full volume is not committed', () {
      registerFile();
      pinToCurrentSize();
      final _Fill fill = fillUntilFull();
      expect(fill.failure, isA<StorageException>());

      // The same statement the commit path issues, followed in one transaction by a
      // write that must allocate. The engine refuses the allocation, so the whole
      // transaction - including the chunk row - must disappear.
      expect(
        () => database.transaction(() {
          database.db.execute(
            "UPDATE chunks SET state = 'committed', committed_at = ? "
            'WHERE file_id = ? AND idx = 0;',
            <Object?>[1, fileId],
          );
          database.db.execute(
            'INSERT INTO peers (peer_id, identity_fingerprint, authorized) '
            'VALUES (?, ?, 0);',
            <Object?>['after-update', 'f' * 64],
          );
        }),
        throwsA(
          isA<StorageException>().having(
            (StorageException e) => e.code,
            'code',
            StorageFailureCode.spaceInsufficient,
          ),
        ),
      );

      expect(
        chunks.committedChunkCount(fileId),
        0,
        reason: '「磁盘满 → 提交失败且不产生 committed」',
      );
      expect(chunks.missingChunkIndices(fileId), <int>[0, 1]);
    });

    test('after space is freed the same work succeeds', () async {
      registerFile();
      final int epoch = chunks.revokeAndAdvanceLease(taskId);
      final int pages = pinToCurrentSize();
      final _Fill fill = fillUntilFull();
      expect(fill.failure, isA<StorageException>());
      final int peersWhileFull = peerCount();

      // The user frees space; the recoverable state is what makes the retry possible.
      database.db.execute('PRAGMA max_page_count = ${pages + 256};');

      expect(
        peerCount(),
        peersWhileFull,
        reason: 'nothing was recorded while the volume was full',
      );
      final StoredChunk committed = await chunks.commitChunkAfterSync(
        taskId: taskId,
        fileId: fileId,
        index: 0,
        bytes: chunkBytes(0),
        leaseEpoch: epoch,
        sink: _WorkingSink(),
      );
      expect(committed.state, ChunkState.committed);
      expect(chunks.committedChunkCount(fileId), 1);
      expect(chunks.missingChunkIndices(fileId), <int>[1]);
    });
  });

  group('commit refusal', () {
    test('a failed durable sync acknowledges nothing', () async {
      registerFile();
      final int epoch = chunks.revokeAndAdvanceLease(taskId);

      await expectLater(
        chunks.commitChunkAfterSync(
          taskId: taskId,
          fileId: fileId,
          index: 0,
          bytes: chunkBytes(0),
          leaseEpoch: epoch,
          sink: _FailingSink(),
        ),
        throwsA(isA<StorageException>()),
      );

      expect(chunks.committedChunkCount(fileId), 0);
      expect(chunks.missingChunkIndices(fileId), <int>[0, 1]);
      expect(chunks.isFullyCommitted(fileId), isFalse);
      expect(
        database.db.select(
          'SELECT state FROM tasks WHERE task_id = ?;',
          <Object?>[taskId],
        ).first['state'],
        'ready',
        reason: 'a refused commit must not be reflected as progress anywhere',
      );
    });

    test('a refused commit does not consume the write generation', () async {
      registerFile();
      final int epoch = chunks.revokeAndAdvanceLease(taskId);

      await expectLater(
        chunks.commitChunkAfterSync(
          taskId: taskId,
          fileId: fileId,
          index: 0,
          bytes: chunkBytes(0),
          leaseEpoch: epoch,
          sink: _FailingSink(),
        ),
        throwsA(isA<StorageException>()),
      );

      expect(
        chunks.leaseEpoch(taskId),
        epoch,
        reason:
            'the same generation must still authorise the retry; burning it would force '
            'a resume for what is a transient write failure',
      );
      final StoredChunk retried = await chunks.commitChunkAfterSync(
        taskId: taskId,
        fileId: fileId,
        index: 0,
        bytes: chunkBytes(0),
        leaseEpoch: epoch,
        sink: _WorkingSink(),
      );
      expect(retried.state, ChunkState.committed);
    });

    test('a failed sync is not recorded against the frozen manifest', () async {
      registerFile();
      final int epoch = chunks.revokeAndAdvanceLease(taskId);

      await expectLater(
        chunks.commitChunkAfterSync(
          taskId: taskId,
          fileId: fileId,
          index: 0,
          bytes: chunkBytes(0),
          leaseEpoch: epoch,
          sink: _FailingSink(),
        ),
        throwsA(isA<StorageException>()),
      );

      final StoredChunk row = chunks.readChunk(fileId, 0);
      expect(row.state, ChunkState.missing);
      expect(
        database.db.select(
          'SELECT committed_at FROM chunks WHERE file_id = ? AND idx = 0;',
          <Object?>[fileId],
        ).first['committed_at'],
        isNull,
        reason:
            'nothing may carry a commit timestamp the commit path never wrote',
      );
      expect(
        row.sha256,
        sha256.convert(chunkBytes(0)).toString(),
        reason: 'the expected digest is from the frozen manifest, not from the peer',
      );
    });
  });
}

/// How far filling the database got.
class _Fill {
  const _Fill({required this.inserted, required this.failure});

  final int inserted;
  final Object? failure;
}

/// Reports the correct digest without writing anything.
///
/// Enough here because these tests exercise ordering and refusal, not the sink.
class _WorkingSink implements DurableChunkSink {
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

/// Models the staging write failing, which is where a full volume is actually met:
/// the bytes that fill the disk are the chunk data, not the database row.
class _FailingSink implements DurableChunkSink {
  @override
  Future<DurableChunkWriteResult> writeVerifyAndSync({
    required String fileId,
    required int index,
    required int offsetBytes,
    required Uint8List bytes,
  }) async {
    throw const StorageException(
      StorageFailureCode.commitFailed,
      'staging write failed',
    );
  }
}
