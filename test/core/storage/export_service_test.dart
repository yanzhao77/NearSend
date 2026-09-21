import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/export_naming.dart';
import 'package:nearsend/core/storage/export_service.dart';
import 'package:nearsend/core/storage/file_verification.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

/// Placing a verified file at the target, then freeing the app's copy.
///
/// Three properties carry the weight. The export record is written **before** staging is
/// released, so a crash never leaves the user with neither a copy nor a record of one; a
/// failed staging release never turns a saved export into a failure; and nothing this
/// service does can delete a file at the target.
void main() {
  late Directory dir;
  late NearSendDatabase database;
  late ChunkRepository chunks;
  late TransferRepository transfers;
  late _RecordingSink sink;

  const String taskId = '00000000-0000-4000-8000-0000000000c1';
  const String fileId = '00000000-0000-4000-8000-0000000000f1';
  const int chunkSize = 4;
  const String contents = 'abcdefgh';
  const String targetRef = 'content://downloads';

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nearsend-export-');
    database = NearSendDatabase.open(
      path: '${dir.path}${Platform.pathSeparator}export.db',
    );
    chunks = ChunkRepository(database);
    transfers = TransferRepository(database);
    sink = _RecordingSink();
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

  /// Registers, commits and verifies a file, leaving it ready to export.
  Future<FileVerificationResult> readyToExport({
    String body = contents,
    String path = 'sample.bin',
    String id = fileId,
  }) async {
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
        relativePath: path,
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
    final Map<String, Uint8List> staged = <String, Uint8List>{};
    for (int i = 0; i < manifest.length; i++) {
      final int start = i * chunkSize;
      final int end = (i + 1) * chunkSize > bytes.length
          ? bytes.length
          : (i + 1) * chunkSize;
      final Uint8List part = Uint8List.sublistView(bytes, start, end);
      staged['$id#$i'] = Uint8List.fromList(part);
      await chunks.commitChunkAfterSync(
        taskId: taskId,
        fileId: id,
        index: i,
        bytes: part,
        leaseEpoch: epoch,
        sink: _Sink(),
      );
    }

    for (final FileState state in <FileState>[
      FileState.preparing,
      FileState.transferring,
      FileState.verifying,
      FileState.exporting,
    ]) {
      transfers.transitionFile(fileId: id, to: state);
    }

    return FileVerifier(
      database,
      reader: _MapReader(staged),
      chunks: chunks,
    ).verifyFile(fileId: id);
  }

  ExportService serviceWith({ExportNamingPolicy? naming}) => ExportService(
    database: database,
    sink: sink,
    transfers: transfers,
    naming: naming ?? const ExportNamingPolicy(),
  );

  group('the order that matters', () {
    test('the record exists before staging is released', () async {
      final FileVerificationResult receipt = await readyToExport();
      bool? recordedWhenStagingWasDeleted;
      sink.onDelete = () {
        recordedWhenStagingWasDeleted =
            transfers.existingExport(fileId)?.isSaved ?? false;
      };

      final ExportOutcome outcome = await serviceWith().exportFile(
        fileId: fileId,
        targetRef: targetRef,
        verification: receipt,
      );

      expect(outcome.isSaved, isTrue);
      expect(outcome.wroteToTarget, isTrue);
      expect(outcome.stagingRelease, StagingRelease.freed);
      expect(
        recordedWhenStagingWasDeleted,
        isTrue,
        reason:
            'staging is the only thing that could still produce the user\'s file, so it '
            'must not be freed until something durable says the copy exists',
      );
    });

    test('staging survives when the export cannot be recorded', () async {
      final FileVerificationResult good = await readyToExport();
      // A receipt for a different file is refused by the record, which is the same shape
      // as any record failure: the bytes are at the target, nothing local says so.
      final FileVerificationResult wrongFile = FileVerificationResult(
        fileId: '00000000-0000-4000-8000-0000000000f9',
        expectedFileSha256: good.expectedFileSha256,
        computedFileSha256: good.computedFileSha256,
        wholeFileDigestMatches: true,
        damagedChunkIndices: const <int>[],
        missingChunkIndices: const <int>[],
        verifiedBytes: good.verifiedBytes,
        expectedBytes: good.expectedBytes,
      );

      final ExportOutcome outcome = await serviceWith().exportFile(
        fileId: fileId,
        targetRef: targetRef,
        verification: wrongFile,
      );

      expect(outcome.kind, ExportOutcomeKind.failed);
      expect(outcome.isRetryable, isTrue);
      expect(outcome.wroteToTarget, isTrue);
      expect(
        outcome.stagingRelease,
        StagingRelease.retained,
        reason:
            'without a record, staging is the only evidence a copy was made',
      );
      expect(sink.deletes, isEmpty);
      expect(transfers.existingExport(fileId), isNull);
    });

    test(
      'a failed staging release does not make the export a failure',
      () async {
        final FileVerificationResult receipt = await readyToExport();
        sink.deleteFails = true;

        final ExportOutcome outcome = await serviceWith().exportFile(
          fileId: fileId,
          targetRef: targetRef,
          verification: receipt,
        );

        expect(
          outcome.isSaved,
          isTrue,
          reason:
              '端侧设计 §7: a cleanup failure only affects space recovery, and the user\'s '
              'file is unaffected by it',
        );
        expect(outcome.stagingRelease, StagingRelease.failed);
        expect(outcome.cleanupFailure, isNotNull);
        expect(transfers.existingExport(fileId)!.isSaved, isTrue);
      },
    );

    test('a failed commit releases nothing', () async {
      final FileVerificationResult receipt = await readyToExport();
      sink.commitFails = true;

      final ExportOutcome outcome = await serviceWith().exportFile(
        fileId: fileId,
        targetRef: targetRef,
        verification: receipt,
      );

      expect(outcome.kind, ExportOutcomeKind.failed);
      expect(outcome.wroteToTarget, isFalse);
      expect(outcome.stagingRelease, StagingRelease.retained);
      expect(sink.deletes, isEmpty);
      expect(transfers.existingExport(fileId), isNull);
    });
  });

  group('refusing to risk the user\'s file', () {
    test('an unlistable target is refused rather than assumed empty', () async {
      final FileVerificationResult receipt = await readyToExport();
      sink.inventoryKnown = false;

      final ExportOutcome outcome = await serviceWith().exportFile(
        fileId: fileId,
        targetRef: targetRef,
        verification: receipt,
      );

      expect(outcome.kind, ExportOutcomeKind.refused);
      expect(outcome.reason, contains('cannot be listed'));
      expect(
        sink.commits,
        isEmpty,
        reason:
            'an unlistable target may already hold the user\'s file under the name we '
            'were about to write; assuming there is no conflict is how a file is lost',
      );
      expect(transfers.existingExport(fileId), isNull);
    });

    test('a file already saved elsewhere is refused', () async {
      final FileVerificationResult receipt = await readyToExport();
      transfers.recordSavedExport(
        fileId: fileId,
        targetUri: 'content://somewhere-else',
        verification: receipt,
        savedPath: 'sample.bin',
      );

      final ExportOutcome outcome = await serviceWith().exportFile(
        fileId: fileId,
        targetRef: targetRef,
        verification: receipt,
      );

      expect(outcome.kind, ExportOutcomeKind.refused);
      expect(sink.commits, isEmpty);
    });

    test('a file already saved here is not written a second time', () async {
      final FileVerificationResult receipt = await readyToExport();
      transfers.recordSavedExport(
        fileId: fileId,
        targetUri: targetRef,
        verification: receipt,
        savedPath: 'sample.bin',
      );

      final ExportOutcome outcome = await serviceWith().exportFile(
        fileId: fileId,
        targetRef: targetRef,
        verification: receipt,
      );

      expect(outcome.isSaved, isTrue);
      expect(outcome.wroteToTarget, isFalse);
      expect(sink.commits, isEmpty);
      expect(sink.deletes, isEmpty);
      expect(outcome.stagingRelease, StagingRelease.notNeeded);
    });

    test('the service only ever commits and releases staging', () async {
      final FileVerificationResult receipt = await readyToExport();
      await serviceWith().exportFile(
        fileId: fileId,
        targetRef: targetRef,
        verification: receipt,
      );

      expect(
        sink.operations,
        <String>['inventory', 'commit:sample.bin', 'deleteStaging'],
        reason:
            'the sink has no delete-at-target capability at all, which is how "cancelling '
            'a task must never delete an exported file" is guaranteed rather than '
            'remembered',
      );
    });
  });

  group('not creating duplicates', () {
    test('an entry that is provably this file is reused', () async {
      final FileVerificationResult receipt = await readyToExport();
      // The state after a crash between committing the copy and writing the record.
      sink.entries = <TargetEntry>[
        TargetEntry(
          path: 'sample.bin',
          sizeBytes: 8,
          sha256: receipt.expectedFileSha256,
        ),
      ];

      final ExportOutcome outcome = await serviceWith().exportFile(
        fileId: fileId,
        targetRef: targetRef,
        verification: receipt,
      );

      expect(outcome.isSaved, isTrue);
      expect(
        outcome.wroteToTarget,
        isFalse,
        reason: 'V2.1 §15: do not blindly create a duplicate file',
      );
      expect(sink.commits, isEmpty);
      expect(
        transfers.existingExport(fileId)!.savedPath,
        'sample.bin',
        reason: 'the record now says where the copy is, closing the window',
      );
      expect(outcome.stagingRelease, StagingRelease.freed);
    });

    test('an entry of the same length but a different digest is not ours', () async {
      final FileVerificationResult receipt = await readyToExport();
      sink.entries = <TargetEntry>[
        TargetEntry(path: 'sample.bin', sizeBytes: 8, sha256: 'f' * 64),
      ];

      final ExportOutcome outcome = await serviceWith().exportFile(
        fileId: fileId,
        targetRef: targetRef,
        verification: receipt,
      );

      expect(outcome.isSaved, isTrue);
      expect(
        outcome.safePath,
        'sample (1).bin',
        reason:
            'an equal size is not proof of identity, so the name is not reused',
      );
      expect(sink.commits, <String>['sample (1).bin']);
    });

    test(
      'an entry whose digest cannot be read cannot be proven ours',
      () async {
        final FileVerificationResult receipt = await readyToExport();
        sink.entries = <TargetEntry>[
          TargetEntry(path: 'sample.bin', sizeBytes: 8),
        ];

        final ExportOutcome outcome = await serviceWith().exportFile(
          fileId: fileId,
          targetRef: targetRef,
          verification: receipt,
        );

        expect(
          outcome.safePath,
          'sample (1).bin',
          reason:
              'a null digest means identity cannot be proven, not that it matched; reusing '
              'it would report a successful export for a file that may not be there',
        );
      },
    );

    test(
      'a proven entry is preferred over renaming even under autoRename',
      () async {
        final FileVerificationResult receipt = await readyToExport();
        sink.entries = <TargetEntry>[
          TargetEntry(
            path: 'sample.bin',
            sizeBytes: 8,
            sha256: receipt.expectedFileSha256,
          ),
        ];

        final ExportOutcome outcome =
            await serviceWith(
              naming: const ExportNamingPolicy(
                conflict: NameConflictPolicy.autoRename,
              ),
            ).exportFile(
              fileId: fileId,
              targetRef: targetRef,
              verification: receipt,
            );

        expect(outcome.safePath, 'sample.bin');
        expect(sink.commits, isEmpty);
      },
    );
  });

  group('the naming policy decides the rest', () {
    test('a taken name is renamed and the renamed path is recorded', () async {
      final FileVerificationResult receipt = await readyToExport();
      sink.entries = <TargetEntry>[TargetEntry(path: 'sample.bin')];

      final ExportOutcome outcome = await serviceWith().exportFile(
        fileId: fileId,
        targetRef: targetRef,
        verification: receipt,
      );

      expect(outcome.safePath, 'sample (1).bin');
      expect(sink.commits, <String>['sample (1).bin']);
      expect(transfers.existingExport(fileId)!.savedPath, 'sample (1).bin');
    });

    test('ask writes nothing and asks', () async {
      final FileVerificationResult receipt = await readyToExport();
      sink.entries = <TargetEntry>[TargetEntry(path: 'sample.bin')];

      final ExportOutcome outcome = await serviceWith(
        naming: const ExportNamingPolicy(conflict: NameConflictPolicy.ask),
      ).exportFile(fileId: fileId, targetRef: targetRef, verification: receipt);

      expect(outcome.kind, ExportOutcomeKind.needsUserDecision);
      expect(sink.commits, isEmpty);
      expect(outcome.stagingRelease, StagingRelease.retained);
      expect(transfers.existingExport(fileId), isNull);
    });

    test('skip writes nothing and leaves the file out', () async {
      final FileVerificationResult receipt = await readyToExport();
      sink.entries = <TargetEntry>[TargetEntry(path: 'sample.bin')];

      final ExportOutcome outcome = await serviceWith(
        naming: const ExportNamingPolicy(conflict: NameConflictPolicy.skip),
      ).exportFile(fileId: fileId, targetRef: targetRef, verification: receipt);

      expect(outcome.kind, ExportOutcomeKind.skipped);
      expect(sink.commits, isEmpty);
      expect(outcome.stagingRelease, StagingRelease.retained);
    });
  });

  group('atomicity is reported, not claimed', () {
    test('a commit that could not be atomic is still a save', () async {
      final FileVerificationResult receipt = await readyToExport();
      sink.atomic = false;

      final ExportOutcome outcome = await serviceWith().exportFile(
        fileId: fileId,
        targetRef: targetRef,
        verification: receipt,
      );

      expect(outcome.isSaved, isTrue);
      expect(
        outcome.committedAtomically,
        isFalse,
        reason:
            'V2.1 §15 forbids describing a document-provider copy as atomic; the fact is '
            'carried so diagnostics cannot imply otherwise',
      );
    });

    test('an atomic commit says so', () async {
      final FileVerificationResult receipt = await readyToExport();

      final ExportOutcome outcome = await serviceWith().exportFile(
        fileId: fileId,
        targetRef: targetRef,
        verification: receipt,
      );

      expect(outcome.committedAtomically, isTrue);
    });

    test('a refusal reports no atomicity at all', () async {
      final FileVerificationResult receipt = await readyToExport();
      sink.inventoryKnown = false;

      final ExportOutcome outcome = await serviceWith().exportFile(
        fileId: fileId,
        targetRef: targetRef,
        verification: receipt,
      );

      expect(
        outcome.committedAtomically,
        isNull,
        reason: 'nothing was committed, so there is nothing to describe',
      );
    });
  });

  group('where the copy is', () {
    test('the frozen path is used when nothing is in the way', () async {
      final FileVerificationResult receipt = await readyToExport(
        path: 'DCIM/photo.jpg',
      );

      final ExportOutcome outcome = await serviceWith().exportFile(
        fileId: fileId,
        targetRef: targetRef,
        verification: receipt,
      );

      expect(outcome.safePath, 'DCIM/photo.jpg');
      expect(transfers.existingExport(fileId)!.savedPath, 'DCIM/photo.jpg');
    });

    test('the recorded path survives being read back', () async {
      final FileVerificationResult receipt = await readyToExport();
      await serviceWith().exportFile(
        fileId: fileId,
        targetRef: targetRef,
        verification: receipt,
      );

      final ExportRecord record = transfers.existingExport(fileId)!;
      expect(record.targetUri, targetRef);
      expect(record.savedPath, 'sample.bin');
      expect(record.isSaved, isTrue);
    });
  });
}

/// Serves staged bytes from memory.
class _MapReader implements StagedChunkReader {
  _MapReader(this.staged);

  final Map<String, Uint8List> staged;

  @override
  Stream<Uint8List> read({required String fileId, required int index}) async* {
    final Uint8List? bytes = staged['$fileId#$index'];
    if (bytes != null) {
      yield bytes;
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

/// A sink that records what it was asked to do, and can be told to fail.
class _RecordingSink implements ExportSink {
  List<TargetEntry> entries = <TargetEntry>[];
  bool inventoryKnown = true;
  bool commitFails = false;
  bool deleteFails = false;
  bool atomic = true;

  /// Called at the moment staging is released, so a test can see what was durable then.
  void Function()? onDelete;

  final List<String> operations = <String>[];
  final List<String> commits = <String>[];
  final List<String> deletes = <String>[];

  @override
  Future<TargetInventory> inventory({required String targetRef}) async {
    operations.add('inventory');
    return inventoryKnown
        ? TargetInventory.known(List<TargetEntry>.of(entries))
        : const TargetInventory.unknown();
  }

  @override
  Future<ExportCommitResult> commit({
    required String fileId,
    required String targetRef,
    required String safePath,
  }) async {
    operations.add('commit:$safePath');
    if (commitFails) {
      throw StateError('the target rejected the write');
    }
    commits.add(safePath);
    entries = <TargetEntry>[
      ...entries,
      TargetEntry(path: safePath, sizeBytes: 0),
    ];
    return ExportCommitResult(atomic: atomic);
  }

  @override
  Future<void> deleteStaging({required String fileId}) async {
    operations.add('deleteStaging');
    onDelete?.call();
    if (deleteFails) {
      throw StateError('the staging file is locked');
    }
    deletes.add(fileId);
  }
}
