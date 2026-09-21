import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/network/chunk_transfer_endpoint.dart';
import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/network/manifest_staging_registry.dart';
import 'package:nearsend/core/network/task_authorization_endpoint.dart';
import 'package:nearsend/core/network/task_ownership.dart';
import 'package:nearsend/core/protocol/chunk_headers.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/export_service.dart';
import 'package:nearsend/core/storage/file_verification.dart';
import 'package:nearsend/core/storage/local_file_layer.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/core/storage/task_authorization_repository.dart';
import 'package:nearsend/core/storage/task_credential_repository.dart';
import 'package:nearsend/core/storage/task_source_repository.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';
import 'package:nearsend/core/transfer/transfer_engine.dart';

/// The transfer engine, end to end, with real files on disk.
///
/// ## What this proves and what it does not
///
/// It proves the **data-plane contract** in both roles: a real file is planned, its manifest is
/// staged and sealed, its chunks are written through §8's write order into a real staging
/// directory, the whole-file digest is recomputed from those bytes, the file is assembled into a
/// real export target, and the receiver's own SQLite rows say the file is complete.
///
/// It does **not** exercise the HTTP/TLS hop. That hop has its own tests
/// (`https_control_transport_test.dart`, `pairing_over_transport_test.dart`) which drive the real
/// `HttpsControlServer` and a pinning client; what was missing was the layer that *uses* the
/// endpoints, and that is what these cases cover.
///
/// The assertions are deliberately about bytes and rows rather than about return values: a test
/// that checked a status code could not tell a file whose bytes arrived from one whose rows say
/// they did.
void main() {
  late Directory root;
  late NearSendDatabase database;
  late TransferRepository transfers;
  late ChunkRepository tasks;
  late ManifestStagingRegistry staging;
  late TaskAuthorizationRepository authorizations;
  late TaskCredentialRepository credentials;
  late TaskSourceRepository sources;
  late LocalStagingLayout layout;
  late StagingFileSink sink;
  late StagingChunkReader reader;
  late ChunkWindowRegistry windows;
  late TransferEngine engine;
  late ChunkTransferEndpoint chunks;

  const String transferId = '11111111-2222-4333-8444-555555555555';
  const String fileId = '00000000-0000-4000-8000-000000000001';

  /// A file that spans more than one 4 MiB chunk plus a short tail, so §8's tail rule and the
  /// file-end checkpoint are both exercised.
  final Uint8List content = Uint8List.fromList(<int>[
    ...List<int>.generate(
      ProtocolLimits.chunkSizeBytes + 1024,
      (int i) => i % 253,
    ),
    ...'NearSend 双向传输'.codeUnits,
  ]);

  File writeSource(String name, List<int> bytes) {
    final File file = File('${root.path}${Platform.pathSeparator}$name');
    file.writeAsBytesSync(bytes);
    return file;
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('nearsend-engine-');
    database = NearSendDatabase.open(
      path: '${root.path}${Platform.pathSeparator}engine.db',
    );
    transfers = TransferRepository(database);
    tasks = ChunkRepository(database);
    staging = ManifestStagingRegistry(transfers: transfers);
    authorizations = TaskAuthorizationRepository(database);
    credentials = TaskCredentialRepository(database);
    sources = TaskSourceRepository(database);
    layout = LocalStagingLayout(
      Directory('${root.path}${Platform.pathSeparator}app'),
    );
    await layout.prepare();
    sink = StagingFileSink(layout);
    reader = StagingChunkReader(layout);
    windows = ChunkWindowRegistry(tasks: tasks);
    engine = TransferEngine(
      database: database,
      transfers: transfers,
      tasks: tasks,
      staging: staging,
      authorizations: authorizations,
      credentials: credentials,
      sources: sources,
      ownership: SqliteTaskOwnership(database),
      layout: layout,
      sink: sink,
      reader: reader,
      verifier: FileVerifier(database, reader: reader, chunks: tasks),
      exporter: ExportService(
        database: database,
        sink: LocalDirectoryExportSink(layout: layout, staging: sink),
        transfers: transfers,
      ),
      windows: windows,
    );
    chunks = ChunkTransferEndpoint(
      tasks: tasks,
      staging: staging,
      windows: windows,
      sink: sink,
    );
  });

  tearDown(() {
    database.close();
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  /// Stages a real file as an outgoing transfer and returns the plan.
  Future<OutgoingPlan> stageOutgoing(TransferDirection direction) async {
    final File source = writeSource('payload.bin', content);
    return engine.prepareOutgoing(
      transferId: transferId,
      direction: direction,
      peerId: 'peer-b',
      choices: <OutgoingFileChoice>[
        OutgoingFileChoice(
          fileId: fileId,
          relativePath: '资料/样例 文件.bin',
          path: source.path,
        ),
      ],
    );
  }

  group('preparing an outgoing transfer', () {
    test(
      'stages a sealed manifest whose digest covers the real file',
      () async {
        final OutgoingPlan plan = await stageOutgoing(
          TransferDirection.serverToClient,
        );

        expect(plan.files.single.manifest.sizeBytes, content.length);
        expect(
          plan.files.single.manifest.fileSha256,
          sha256.convert(content).toString(),
          reason: '§5.2 hashes the raw file bytes, so the manifest must too',
        );
        expect(
          plan.files.single.manifest.chunkCount,
          2,
          reason: '4 MiB + a tail is two chunks',
        );

        final FrozenManifest? frozen = staging.frozenManifest(transferId);
        expect(frozen, isNotNull);
        expect(frozen!.manifestDigest, plan.manifestDigest);
        expect(
          transfers.taskState(transferId),
          TransferState.waitingAccept,
          reason:
              '§10 puts a sealed transfer in WAITING_ACCEPT and nothing may move before the '
              'receiver accepts',
        );
        expect(
          tasks.leaseEpoch(transferId),
          0,
          reason: 'no write generation exists until a resume allocates one',
        );
      },
    );

    test(
      'leaves the transfer with no write generation until acceptance',
      () async {
        await stageOutgoing(TransferDirection.serverToClient);
        expect(
          () => chunks.putChunk(
            transferId: transferId,
            fileId: fileId,
            index: 0,
            headers: <String, String>{
              'authorization': 'Bearer ${'A' * 43}',
              'content-type': chunkContentType,
              'content-length': '1',
              'x-lft-lease-epoch': '0',
              'x-lft-manifest-digest': staging
                  .frozenManifest(transferId)!
                  .manifestDigest,
            },
            body: Uint8List.fromList(<int>[0]),
          ),
          throwsA(isA<Object>()),
          reason: 'generation 0 means "not allocated", so §8 refuses a commit that presents it',
        );
      },
    );
  });

  group('client_to_server: this node is the receiver', () {
    /// Accepts the transfer the way a server receiver does, then receives the chunks the way a
    /// client sender would send them.
    Future<ReceivedFileOutcome> receiveAll({required String? exportTo}) async {
      final OutgoingPlan plan = await stageOutgoing(
        TransferDirection.clientToServer,
      );
      engine.acceptLocally(
        transferId: transferId,
        context: ReceiverStorageContext(
          stagingVolume: const VolumeId('staging'),
          exportVolume: const VolumeId('internal'),
          databaseVolume: const VolumeId('internal'),
          availability: <VolumeId, VolumeAvailability>{
            const VolumeId('staging'): const VolumeAvailability.known(1 << 40),
            const VolumeId('internal'): const VolumeAvailability.known(1 << 40),
          },
          saveLocationRef: exportTo == null ? null : 'volume:internal',
        ),
      );
      final int epoch = tasks.revokeAndAdvanceLease(transferId);

      // The chunks are produced by the same engine that planned them, so this is a real sender
      // path rather than a fixture handing over bytes.
      for (final ManifestFile file in plan.manifest.files) {
        final SourceFilePlan sourcePlan = engine.planFor(
          transferId,
          file.fileId,
        );
        for (final chunk in sourcePlan.chunks) {
          final Uint8List bytes = _readChunk(sourcePlan, chunk.index);
          await engine.acceptChunk(
            transferId: transferId,
            fileId: file.fileId,
            index: chunk.index,
            bytes: bytes,
            leaseEpoch: epoch,
          );
        }
      }
      // §8 requires a checkpoint at a file end, and the boundary flag in `acceptChunk` takes it;
      // this flushes anything a shorter file would have left pending.
      windows.flushTask(transferId, leaseEpoch: epoch);

      return engine.finishFile(fileId: fileId, targetRef: exportTo);
    }

    test('receives every chunk, verifies the whole file and exports it', () async {
      final Directory target = Directory(
        '${root.path}${Platform.pathSeparator}exports',
      );
      final ReceivedFileOutcome outcome = await receiveAll(
        exportTo: target.path,
      );

      expect(
        outcome.verification.missingChunkIndices,
        isEmpty,
        reason: 'every chunk of the frozen manifest arrived',
      );
      expect(
        outcome.verification.damagedChunkIndices,
        isEmpty,
        reason: 'no chunk failed its digest',
      );
      expect(
        outcome.verification.wholeFileDigestMatches,
        isTrue,
        reason: 'the whole-file digest is recomputed over the staged bytes',
      );
      expect(outcome.verification.verifiedBytes, content.length);
      expect(
        outcome.export!.kind,
        ExportOutcomeKind.saved,
        reason:
            'the export must actually commit: ${outcome.export!.reason ?? 'no reason given'}',
      );
      expect(outcome.isComplete, isTrue);

      final List<File> written = target
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => !f.path.endsWith('.nearsend-part'))
          .toList();
      expect(written, hasLength(1));
      expect(
        written.single.readAsBytesSync(),
        content,
        reason:
            'the exported file must be byte-identical, which is what the caller checks '
            'instead of trusting a status',
      );
      expect(
        sha256.convert(written.single.readAsBytesSync()).toString(),
        sha256.convert(content).toString(),
      );
      expect(
        tasks.isFullyCommitted(fileId),
        isTrue,
        reason: 'the receiver own rows say the file is complete',
      );
    });

    test(
      'a chunk with the wrong bytes is refused and the file stays incomplete',
      () async {
        await stageOutgoing(TransferDirection.clientToServer);
        engine.acceptLocally(
          transferId: transferId,
          context: ReceiverStorageContext(
            stagingVolume: const VolumeId('staging'),
            exportVolume: const VolumeId('internal'),
            databaseVolume: const VolumeId('internal'),
            availability: <VolumeId, VolumeAvailability>{
              const VolumeId('staging'): const VolumeAvailability.known(
                1 << 40,
              ),
              const VolumeId('internal'): const VolumeAvailability.known(
                1 << 40,
              ),
            },
          ),
        );
        final int epoch = tasks.revokeAndAdvanceLease(transferId);
        final SourceFilePlan plan = engine.planFor(transferId, fileId);
        final Uint8List wrong = _readChunk(plan, 0);
        wrong[3] = wrong[3] ^ 0xFF;

        await expectLater(
          engine.acceptChunk(
            transferId: transferId,
            fileId: fileId,
            index: 0,
            bytes: wrong,
            leaseEpoch: epoch,
          ),
          throwsA(isA<Object>()),
        );

        final FileVerificationResult verification = await engine
            .finishFile(fileId: fileId)
            .then((ReceivedFileOutcome o) => o.verification);
        expect(
          verification.isExportable,
          isFalse,
          reason: 'a file whose bytes are wrong must never become exportable',
        );
        expect(
          transfers.fileState(fileId),
          isNot(FileState.completed),
          reason: 'and it must not be marked complete either',
        );
      },
    );

    test('a resumed receive only asks for what is missing', () async {
      await stageOutgoing(TransferDirection.clientToServer);
      engine.acceptLocally(
        transferId: transferId,
        context: ReceiverStorageContext(
          stagingVolume: const VolumeId('staging'),
          exportVolume: const VolumeId('internal'),
          databaseVolume: const VolumeId('internal'),
          availability: <VolumeId, VolumeAvailability>{
            const VolumeId('staging'): const VolumeAvailability.known(1 << 40),
            const VolumeId('internal'): const VolumeAvailability.known(1 << 40),
          },
        ),
      );
      final int epoch = tasks.revokeAndAdvanceLease(transferId);
      final SourceFilePlan plan = engine.planFor(transferId, fileId);

      await engine.acceptChunk(
        transferId: transferId,
        fileId: fileId,
        index: 1,
        bytes: _readChunk(plan, 1),
        leaseEpoch: epoch,
      );

      expect(
        engine.missingChunks(fileId),
        <int>[0],
        reason:
            'recovery reads the committed rows, so a restart asks for exactly what did not '
            'arrive - the tail arriving first must not make the head look present',
      );
    });
  });

  group('server_to_client: this node is the sender', () {
    test('serves the chunks a receiver asks for, byte for byte', () async {
      final OutgoingPlan plan = await stageOutgoing(
        TransferDirection.serverToClient,
      );
      final int epoch = tasks.revokeAndAdvanceLease(transferId);

      final ChunkTransferEndpoint serving = ChunkTransferEndpoint(
        tasks: tasks,
        staging: staging,
        windows: windows,
        sink: sink,
        source: _EngineSource(engine),
      );

      for (final ManifestFile file in plan.manifest.files) {
        for (int index = 0; index < file.chunkCount; index++) {
          final ControlResponse response = await serving.getChunk(
            transferId: transferId,
            fileId: file.fileId,
            index: index,
            headers: <String, String>{
              'authorization': 'Bearer ${'A' * 43}',
              'x-lft-lease-epoch': '$epoch',
              'x-lft-manifest-digest': plan.manifestDigest,
            },
          );
          final SourceFilePlan sourcePlan = engine.planFor(
            transferId,
            file.fileId,
          );
          expect(
            response.body,
            _readChunk(sourcePlan, index),
            reason: 'the served bytes are the source bytes for chunk $index',
          );
        }
      }
    });
  });
}

/// Reads one chunk of a planned source, with a single bounded buffer.
Uint8List _readChunk(SourceFilePlan plan, int index) {
  final RandomAccessFile handle = plan.file.openSync();
  try {
    final record = plan.chunks[index];
    handle.setPositionSync(record.index * ProtocolLimits.chunkSizeBytes);
    final Uint8List bytes = Uint8List(record.length);
    int filled = 0;
    while (filled < record.length) {
      final int read = handle.readIntoSync(
        bytes,
        filled,
        record.length - filled,
      );
      if (read <= 0) {
        break;
      }
      filled += read;
    }
    return bytes;
  } finally {
    handle.closeSync();
  }
}

/// Serves a sender's chunks from the engine's recorded sources.
class _EngineSource implements OutgoingChunkSource {
  _EngineSource(this.engine);

  final TransferEngine engine;

  @override
  Future<Uint8List> readChunk({
    required String transferId,
    required String fileId,
    required int offsetBytes,
    required int length,
  }) async {
    final SourceFilePlan plan = engine.planFor(transferId, fileId);
    return _readChunk(plan, offsetBytes ~/ ProtocolLimits.chunkSizeBytes);
  }
}
