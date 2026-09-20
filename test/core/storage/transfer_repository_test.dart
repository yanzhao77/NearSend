import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_failure.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

/// Task and file state persistence, and the export guards.
///
/// Two behaviours matter most here. State changes must go through the T02-02 machines, so
/// an undefined edge is refused rather than stored; and an export must never be recorded
/// for a file whose chunks are not all committed, nor a second copy recorded silently.
void main() {
  late Directory dir;
  late NearSendDatabase database;
  late ChunkRepository chunks;
  late TransferRepository transfers;

  const String taskId = '00000000-0000-4000-8000-0000000000c1';
  const String fileId = '00000000-0000-4000-8000-0000000000f1';
  const int chunkSize = 4;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nearsend-transfer-');
    database = NearSendDatabase.open(
      path: '${dir.path}${Platform.pathSeparator}t.db',
    );
    chunks = ChunkRepository(database);
    transfers = TransferRepository(database);
    chunks.registerTask(
      taskId: taskId,
      role: 'receiver',
      direction: 'client_to_server',
      state: TransferState.ready.name,
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

  /// Registers a file of [contents] split into `chunkSize`-byte chunks.
  void registerFile(String contents, {String id = fileId}) {
    final Uint8List bytes = Uint8List.fromList(contents.codeUnits);
    final int count = bytes.isEmpty
        ? 0
        : (bytes.length + chunkSize - 1) ~/ chunkSize;
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

  /// Moves a file from `pending` along the defined chain until it reaches [target].
  void driveFileTo(String fileId, FileState target) {
    const List<FileState> chain = <FileState>[
      FileState.preparing,
      FileState.transferring,
      FileState.verifying,
      FileState.exporting,
      FileState.completed,
    ];
    for (final FileState state in chain) {
      transfers.transitionFile(fileId: fileId, to: state);
      if (state == target) {
        return;
      }
    }
  }

  /// Registers a file and durably commits every chunk of it.
  ///
  /// Export is only reachable for a file whose bytes are all present, so a test that
  /// wants to exercise the export path has to actually get there rather than writing the
  /// state directly.
  Future<void> registerAndCommit(String contents, {String id = fileId}) async {
    registerFile(contents, id: id);
    final Uint8List bytes = Uint8List.fromList(contents.codeUnits);
    final int epoch = chunks.revokeAndAdvanceLease(taskId);
    for (int offset = 0; offset < bytes.length; offset += chunkSize) {
      final int end = offset + chunkSize > bytes.length
          ? bytes.length
          : offset + chunkSize;
      await chunks.commitChunkAfterSync(
        taskId: taskId,
        fileId: id,
        index: offset ~/ chunkSize,
        bytes: Uint8List.sublistView(bytes, offset, end),
        leaseEpoch: epoch,
        sink: _DirectSink(),
      );
    }
  }

  group('task state', () {
    test('a defined transition is stored', () {
      expect(transfers.taskState(taskId), TransferState.ready);
      expect(
        transfers.transitionTask(
          taskId: taskId,
          to: TransferState.transferring,
        ),
        TransferState.transferring,
      );
      expect(transfers.taskState(taskId), TransferState.transferring);
    });

    test('an undefined transition is refused and nothing is written', () {
      expect(
        () => transfers.transitionTask(
          taskId: taskId,
          to: TransferState.completed,
        ),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.invalidState,
          ),
        ),
        reason: 'READY -> COMPLETED is not an edge in §10',
      );
      expect(transfers.taskState(taskId), TransferState.ready);
    });

    test('an unknown task is reported rather than created', () {
      expect(
        () => transfers.taskState('00000000-0000-4000-8000-0000000000ff'),
        throwsA(isA<StorageException>()),
      );
    });

    test('a whole defined path can be walked', () {
      for (final TransferState state in <TransferState>[
        TransferState.transferring,
        TransferState.pausing,
        TransferState.paused,
        TransferState.checkingResume,
        TransferState.ready,
        TransferState.transferring,
        TransferState.verifying,
        TransferState.exporting,
        TransferState.completed,
      ]) {
        transfers.transitionTask(taskId: taskId, to: state);
      }
      expect(transfers.taskState(taskId), TransferState.completed);
    });
  });

  group('file state', () {
    test('files are listed in registration order', () {
      registerFile('abcdefgh');
      registerFile('abcd', id: '00000000-0000-4000-8000-0000000000f2');
      expect(transfers.fileIds(taskId), <String>[
        fileId,
        '00000000-0000-4000-8000-0000000000f2',
      ]);
    });

    test('an undefined file transition is refused', () {
      registerFile('abcd');
      expect(
        () => transfers.transitionFile(fileId: fileId, to: FileState.completed),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.invalidState,
          ),
        ),
        reason:
            'pending -> completed skips preparation, transfer and verification',
      );
      expect(transfers.fileState(fileId), FileState.pending);
    });

    test('a skipped file is terminal', () {
      registerFile('abcd');
      transfers.transitionFile(fileId: fileId, to: FileState.skipped);
      expect(
        () => transfers.transitionFile(fileId: fileId, to: FileState.preparing),
        throwsA(isA<ProtocolViolation>()),
      );
    });
  });

  group('export records', () {
    test('an export cannot be recorded while a chunk is uncommitted', () async {
      registerFile('abcdefgh'); // two chunks
      driveFileTo(fileId, FileState.exporting);
      final int epoch = chunks.revokeAndAdvanceLease(taskId);

      // Commit only the first chunk.
      await chunks.commitChunkAfterSync(
        taskId: taskId,
        fileId: fileId,
        index: 0,
        bytes: Uint8List.fromList('abcd'.codeUnits),
        leaseEpoch: epoch,
        sink: _DirectSink(),
      );

      expect(
        () => transfers.recordSavedExport(
          fileId: fileId,
          targetUri: 'content://a',
        ),
        throwsA(
          isA<StorageException>().having(
            (StorageException e) => e.code,
            'code',
            StorageFailureCode.manifestMismatch,
          ),
        ),
        reason:
            'recording an export for a file whose bytes are incomplete would tell the '
            'user their file was saved when it was not',
      );
      expect(transfers.existingExport(fileId), isNull);
      expect(transfers.fileState(fileId), FileState.exporting);
    });

    test('a failed export does not overwrite a saved record', () async {
      await registerAndCommit('abcd');
      driveFileTo(fileId, FileState.exporting);
      final ExportRecord saved = transfers.recordSavedExport(
        fileId: fileId,
        targetUri: 'content://a',
      );
      expect(saved.isSaved, isTrue);
      expect(transfers.fileState(fileId), FileState.completed);

      final ExportRecord afterFailure = transfers.recordFailedExport(
        fileId: fileId,
        targetUri: 'content://b',
      );
      expect(
        afterFailure.targetUri,
        'content://a',
        reason:
            'the user copy at the original target still exists; a later failure must '
            'not erase that fact',
      );
      expect(afterFailure.isSaved, isTrue);
    });

    test('recording the same target twice is idempotent', () async {
      await registerAndCommit('abcd');
      driveFileTo(fileId, FileState.exporting);

      final ExportRecord first = transfers.recordSavedExport(
        fileId: fileId,
        targetUri: 'content://a',
      );
      final ExportRecord second = transfers.recordSavedExport(
        fileId: fileId,
        targetUri: 'content://a',
      );

      expect(second.targetUri, first.targetUri);
      expect(
        second.recordedAtMillis,
        first.recordedAtMillis,
        reason: 'the existing row is returned, not rewritten',
      );
      expect(
        database.db.select('SELECT COUNT(*) AS c FROM exports;').first['c'],
        1,
      );
    });

    test('a second copy at a different target is refused', () async {
      await registerAndCommit('abcd');
      driveFileTo(fileId, FileState.exporting);
      transfers.recordSavedExport(fileId: fileId, targetUri: 'content://a');

      expect(
        () => transfers.recordSavedExport(
          fileId: fileId,
          targetUri: 'content://b',
        ),
        throwsA(
          isA<StorageException>().having(
            (StorageException e) => e.code,
            'code',
            StorageFailureCode.manifestMismatch,
          ),
        ),
        reason:
            '§10 forbids blindly producing a second file when the first result is '
            'already known to be saved',
      );
      expect(transfers.existingExport(fileId)!.targetUri, 'content://a');
    });

    test(
      'a retry after a failed export succeeds and completes the file',
      () async {
        await registerAndCommit('abcd');
        driveFileTo(fileId, FileState.exporting);

        final ExportRecord failed = transfers.recordFailedExport(
          fileId: fileId,
          targetUri: 'content://a',
        );
        expect(failed.isSaved, isFalse);
        expect(
          transfers.fileState(fileId),
          FileState.exporting,
          reason: 'a failure must leave the file retryable, not terminal',
        );

        final ExportRecord saved = transfers.recordSavedExport(
          fileId: fileId,
          targetUri: 'content://a',
        );
        expect(saved.isSaved, isTrue);
        expect(transfers.fileState(fileId), FileState.completed);
      },
    );
  });
}

/// Writes nothing but reports the correct digest, which is enough here because these
/// tests exercise the state and export logic rather than the sink.
class _DirectSink implements DurableChunkSink {
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
