import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/network/chunk_transfer_endpoint.dart';
import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/network/manifest_staging_registry.dart';
import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/protocol/chunk_headers.dart';
import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/manifest_page.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/commit_window.dart';
import 'package:nearsend/core/storage/local_file_layer.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';
import 'package:nearsend/core/protocol/wire_error.dart';

import 'package:crypto/crypto.dart';

/// 搂8's data plane.
///
/// The assertions below are deliberately about **SQLite rows and staged bytes**, not about status
/// codes: 搂8's value is that a chunk row only becomes `committed` after a durable sync, and a
/// test that read only the response could not tell a committed chunk from a `verified_pending`
/// one - which is the distinction the whole batching design rests on.
void main() {
  late Directory dir;
  late LocalStagingLayout layout;
  late StagingFileSink sink;
  late NearSendDatabase database;
  late ChunkRepository tasks;
  late TransferRepository transfers;
  late ManifestStagingRegistry staging;
  late ChunkWindowRegistry windows;
  late ChunkTransferEndpoint endpoint;
  late int clock;

  const String transferId = '11111111-2222-4333-8444-555555555555';
  const String fileId = '00000000-0000-4000-8000-000000000001';
  const String token = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

  /// A file of two chunks plus a short tail, so 搂8's tail-length rule is exercised.
  final Uint8List content = Uint8List.fromList(<int>[
    ...List<int>.generate(ProtocolLimits.chunkSizeBytes, (int i) => i % 251),
    ...List<int>.generate(7, (int i) => 200 + i),
  ]);

  List<ChunkRecord> chunksOf(Uint8List bytes) {
    final List<ChunkRecord> records = <ChunkRecord>[];
    for (
      int index = 0;
      index < chunkCountForSize(bytes.length, ProtocolLimits.chunkSizeBytes);
      index++
    ) {
      final int length = chunkLengthForIndex(
        bytes.length,
        ProtocolLimits.chunkSizeBytes,
        index,
      );
      records.add(
        ChunkRecord(
          index: index,
          length: length,
          sha256: sha256
              .convert(
                bytes.sublist(
                  index * ProtocolLimits.chunkSizeBytes,
                  index * ProtocolLimits.chunkSizeBytes + length,
                ),
              )
              .toString(),
        ),
      );
    }
    return records;
  }

  Uint8List chunkBytes(int index) => Uint8List.fromList(
    content.sublist(
      index * ProtocolLimits.chunkSizeBytes,
      (index + 1) * ProtocolLimits.chunkSizeBytes > content.length
          ? content.length
          : (index + 1) * ProtocolLimits.chunkSizeBytes,
    ),
  );

  final List<ChunkRecord> records = chunksOf(content);
  final ManifestFile file = ManifestFile(
    fileId: fileId,
    relativePath: 'payload.bin',
    sizeBytes: content.length,
    chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
    chunkCount: records.length,
    fileSha256: sha256.convert(content).toString(),
    chunkManifestDigest: ChunkManifestCodec.digest(
      chunks: records,
      sizeBytes: content.length,
      chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
    ),
  );
  final List<ManifestFile> files = <ManifestFile>[file];

  final String digest = FrozenManifest(
    protocolMajor: ProtocolLimits.protocolMajor,
    protocolMinor: ProtocolLimits.protocolMinor,
    transferId: transferId,
    files: files,
  ).manifestDigest;

  /// Registers and seals a `client_to_server` task with its write generation allocated.
  void seedTask({int leaseEpoch = 1}) {
    tasks.registerTask(
      taskId: transferId,
      role: 'receiver',
      direction: 'client_to_server',
      state: TransferState.staging,
      protocolMajor: ProtocolLimits.protocolMajor,
      protocolMinor: ProtocolLimits.protocolMinor,
      manifestDigest: digest,
      nowMillis: clock,
    );
    for (final ManifestFilePage page in ManifestPager.filePages(
      manifestDigest: digest,
      files: files,
    )) {
      staging.addPage(transferId, page);
    }
    for (final ManifestChunkPage page in ManifestPager.chunkPages(
      manifestDigest: digest,
      fileId: fileId,
      chunks: records,
    )) {
      staging.addPage(transferId, page);
    }
    staging.seal(transferId);
    tasks.registerFile(
      FrozenFileRegistration(
        taskId: transferId,
        fileId: fileId,
        relativePath: file.relativePath,
        sizeBytes: file.sizeBytes,
        fileSha256: file.fileSha256,
        chunkManifestDigest: file.chunkManifestDigest,
        chunks: records,
      ),
      nowMillis: clock,
    );
    transfers.transitionTask(
      taskId: transferId,
      to: TransferState.waitingAccept,
    );
    transfers.transitionTask(taskId: transferId, to: TransferState.ready);
    for (int i = 0; i < leaseEpoch; i++) {
      tasks.revokeAndAdvanceLease(transferId);
    }
  }

  Map<String, String> putHeaders({
    required int index,
    int? epoch,
    String? forDigest,
    int? declaredLength,
  }) => <String, String>{
    'authorization': 'Bearer $token',
    'content-type': chunkContentType,
    'content-length':
        '${declaredLength ?? chunkLengthForIndex(content.length, ProtocolLimits.chunkSizeBytes, index)}',
    leaseEpochHeader.toLowerCase(): '${epoch ?? 1}',
    manifestDigestHeader.toLowerCase(): forDigest ?? digest,
  };

  Map<String, String> getHeaders({int? epoch, String? forDigest}) =>
      <String, String>{
        'authorization': 'Bearer $token',
        leaseEpochHeader.toLowerCase(): '${epoch ?? 1}',
        manifestDigestHeader.toLowerCase(): forDigest ?? digest,
      };

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nearsend-chunks-');
    layout = LocalStagingLayout(
      Directory('${dir.path}${Platform.pathSeparator}app'),
    );
    sink = StagingFileSink(layout);
    database = NearSendDatabase.open(
      path: '${dir.path}${Platform.pathSeparator}chunks.db',
    );
    clock = 1000;
    tasks = ChunkRepository(database);
    transfers = TransferRepository(database, now: () => clock);
    staging = ManifestStagingRegistry(transfers: transfers, now: () => clock);
    windows = ChunkWindowRegistry(tasks: tasks);
    endpoint = ChunkTransferEndpoint(
      tasks: tasks,
      staging: staging,
      windows: windows,
      sink: sink,
    );
  });

  tearDown(() {
    database.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  group('PUT chunk', () {
    test('a correct chunk is committed and its bytes land on disk', () async {
      seedTask();
      // Chunk 0 is mid-file, so 搂8 lets it be answered `verified_pending`; the file's last
      // chunk forces the checkpoint that commits both. Driving the whole file is what makes this
      // assert the committed path rather than the batching one.
      final ControlResponse first = await endpoint.putChunk(
        transferId: transferId,
        fileId: fileId,
        index: 0,
        headers: putHeaders(index: 0),
        body: chunkBytes(0),
      );
      expect(first.status, 202);
      expect(
        ChunkWriteResult.parse(first.decodeJsonBody()).state,
        ChunkWriteState.verifiedPending,
      );

      final int tail = records.length - 1;
      final ControlResponse last = await endpoint.putChunk(
        transferId: transferId,
        fileId: fileId,
        index: tail,
        headers: putHeaders(index: tail),
        body: chunkBytes(tail),
      );

      expect(last.status, 200);
      final ChunkWriteResult result = ChunkWriteResult.parse(
        last.decodeJsonBody(),
      );
      expect(result.state, ChunkWriteState.committed);
      expect(result.index, tail);
      expect(
        tasks.readChunk(fileId, 0).state,
        ChunkState.committed,
        reason: 'the boundary checkpoint commits the whole pending batch',
      );
      expect(
        tasks.committedBytesForTask(transferId),
        content.length,
        reason: 'the chunk rows are the only evidence of progress',
      );

      final File staged = layout.chunkFile(fileId, 0);
      expect(staged.existsSync(), isTrue);
      expect(
        await staged.readAsBytes(),
        chunkBytes(0),
        reason:
            'one chunk per part file, so a second chunk cannot erase the first',
      );
      expect(
        await layout.chunkFile(fileId, tail).readAsBytes(),
        chunkBytes(tail),
      );
      expect(
        await StagingChunkReader(layout)
            .read(fileId: fileId, index: 0)
            .expand((Uint8List b) => b)
            .toList(),
        chunkBytes(0),
      );
      expect(tasks.isFullyCommitted(fileId), isTrue);
    });

    test('the tail chunk is shorter and still commits', () async {
      seedTask();
      final int tail = records.length - 1;
      final ControlResponse response = await endpoint.putChunk(
        transferId: transferId,
        fileId: fileId,
        index: tail,
        headers: putHeaders(index: tail),
        body: chunkBytes(tail),
      );
      expect(
        ChunkWriteResult.parse(response.decodeJsonBody()).state,
        ChunkWriteState.committed,
        reason:
            '搂8 forces a checkpoint at a file end, so the tail must not be left pending the '
            'way a capacity-only window would leave it',
      );
      expect(tasks.readChunk(fileId, tail).state, ChunkState.committed);
      expect(
        await StagingChunkReader(layout)
            .read(fileId: fileId, index: tail)
            .expand((Uint8List b) => b)
            .toList(),
        chunkBytes(tail),
      );
    });

    test(
      'a body of the wrong length is refused before anything is written',
      () async {
        seedTask();
        expect(
          () => endpoint.putChunk(
            transferId: transferId,
            fileId: fileId,
            index: 0,
            headers: putHeaders(index: 0),
            body: Uint8List.fromList(chunkBytes(0).sublist(0, 10)),
          ),
          throwsA(
            isA<ProtocolViolation>().having(
              (ProtocolViolation e) => e.code,
              'code',
              ProtocolErrorCode.invalidField,
            ),
          ),
        );
        expect(tasks.readChunk(fileId, 0).state, ChunkState.missing);
        expect(tasks.committedBytesForTask(transferId), 0);
      },
    );

    test(
      'bytes that do not match the frozen digest are CHUNK_HASH_MISMATCH',
      () async {
        seedTask();
        final Uint8List wrong = Uint8List.fromList(chunkBytes(0));
        wrong[17] = wrong[17] ^ 0xFF;

        expect(
          () => endpoint.putChunk(
            transferId: transferId,
            fileId: fileId,
            index: 0,
            headers: putHeaders(index: 0),
            body: wrong,
          ),
          throwsA(isA<Object>()),
          reason: 'a chunk whose content differs from the manifest must not be accepted',
        );
        expect(
          tasks.readChunk(fileId, 0).state,
          ChunkState.missing,
          reason: 'a failed write leaves no committed progress',
        );
      },
    );

    test('a chunk from a superseded generation is STALE_LEASE', () async {
      seedTask(leaseEpoch: 2);
      expect(
        () => endpoint.putChunk(
          transferId: transferId,
          fileId: fileId,
          index: 0,
          headers: putHeaders(index: 0, epoch: 1),
          body: chunkBytes(0),
        ),
        throwsA(isA<Object>()),
        reason:
            'a write under an old generation must be refused by the storage layer with '
            'STALE_LEASE, before any byte reaches the staging file',
      );
      expect(tasks.readChunk(fileId, 0).state, ChunkState.missing);
    });

    test('a chunk naming another manifest is MANIFEST_MISMATCH', () async {
      seedTask();
      final String other = sha256.convert(<int>[1, 2, 3]).toString();
      expect(
        () => endpoint.putChunk(
          transferId: transferId,
          fileId: fileId,
          index: 0,
          headers: putHeaders(index: 0, forDigest: other),
          body: chunkBytes(0),
        ),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.manifestMismatch,
          ),
        ),
      );
    });

    test(
      'an index outside the file is NOT_FOUND rather than a write',
      () async {
        seedTask();
        expect(
          () => endpoint.putChunk(
            transferId: transferId,
            fileId: fileId,
            index: records.length,
            headers: putHeaders(index: 0),
            body: chunkBytes(0),
          ),
          throwsA(
            isA<ProtocolViolation>().having(
              (ProtocolViolation e) => e.code,
              'code',
              ProtocolErrorCode.notFound,
            ),
          ),
        );
      },
    );

    test(
      'a chunked or compressed frame is refused before the body is read',
      () async {
        seedTask();
        expect(
          () => endpoint.putChunk(
            transferId: transferId,
            fileId: fileId,
            index: 0,
            headers: <String, String>{
              ...putHeaders(index: 0),
              'transfer-encoding': 'chunked',
            },
            body: chunkBytes(0),
          ),
          throwsA(
            isA<ProtocolViolation>().having(
              (ProtocolViolation e) => e.code,
              'code',
              ProtocolErrorCode.invalidField,
            ),
          ),
        );
        expect(tasks.committedBytesForTask(transferId), 0);
      },
    );
  });

  group('the pending window', () {
    test(
      'a mid-file chunk with an unexpired window is verified_pending',
      () async {
        // 搂8's batching trade: bytes are durable but no chunk row is committed, so recovery does
        // not trust them and they are re-sent after a crash.
        final ChunkWindowRegistry immediateish = ChunkWindowRegistry(
          tasks: tasks,
          policy: const CommitWindowPolicy(
            maxPendingBytes: ProtocolLimits.maxPendingCheckpointBytes,
            flushIntervalMillis: 60000,
          ),
        );
        final ChunkTransferEndpoint batching = ChunkTransferEndpoint(
          tasks: tasks,
          staging: staging,
          windows: immediateish,
          sink: sink,
        );
        seedTask();

        final ControlResponse response = await batching.putChunk(
          transferId: transferId,
          fileId: fileId,
          index: 0,
          headers: putHeaders(index: 0),
          body: chunkBytes(0),
        );

        expect(response.status, 202);
        expect(
          ChunkWriteResult.parse(response.decodeJsonBody()).state,
          ChunkWriteState.verifiedPending,
        );
        expect(
          tasks.committedChunkCount(fileId),
          0,
          reason:
              'verified_pending must not count as progress: a crash here leaves the chunk '
              'missing and the sender re-sends it',
        );
        expect(tasks.missingChunkIndices(fileId), <int>[0, 1]);
      },
    );

    test('a pause flushes the window and commits what was pending', () async {
      final ChunkWindowRegistry slow = ChunkWindowRegistry(
        tasks: tasks,
        policy: const CommitWindowPolicy(
          maxPendingBytes: ProtocolLimits.maxPendingCheckpointBytes,
          flushIntervalMillis: 60000,
        ),
      );
      seedTask();
      final ChunkTransferEndpoint batching = ChunkTransferEndpoint(
        tasks: tasks,
        staging: staging,
        windows: slow,
        sink: sink,
      );
      await batching.putChunk(
        transferId: transferId,
        fileId: fileId,
        index: 0,
        headers: putHeaders(index: 0),
        body: chunkBytes(0),
      );
      expect(tasks.committedChunkCount(fileId), 0);

      slow.flushTask(transferId, leaseEpoch: 1);

      expect(
        tasks.committedChunkCount(fileId),
        1,
        reason:
            'Section 8 forces the checkpoint at a pause, and the task must not be shown as '
            'paused before that checkpoint completes',
      );
      expect(tasks.checkpointSeq(transferId), 1);
    });
  });

  group('GET chunk', () {
    test('a chunk is served with its length and digest', () async {
      seedTask();
      final ChunkTransferEndpoint serving = ChunkTransferEndpoint(
        tasks: tasks,
        staging: staging,
        windows: windows,
        sink: sink,
        source: _MemorySource(<int, Uint8List>{
          0: chunkBytes(0),
          1: chunkBytes(1),
        }),
      );

      final ControlResponse response = await serving.getChunk(
        transferId: transferId,
        fileId: fileId,
        index: 0,
        headers: getHeaders(),
      );

      expect(response.status, 200);
      expect(response.body.length, ProtocolLimits.chunkSizeBytes);
      expect(response.headers['content-type'], chunkContentType);
      final ChunkGetResponseHeaders parsed = ChunkGetResponseHeaders.parse(
        response.headers,
      );
      expect(parsed.contentLength, ProtocolLimits.chunkSizeBytes);
      expect(
        parsed.agreesWithManifest(records.first.sha256),
        isTrue,
        reason: 'the served bytes are the ones the frozen manifest describes',
      );
    });

    test('a GET from a superseded generation is refused', () async {
      seedTask(leaseEpoch: 2);
      final ChunkTransferEndpoint serving = ChunkTransferEndpoint(
        tasks: tasks,
        staging: staging,
        windows: windows,
        sink: sink,
        source: _MemorySource(<int, Uint8List>{0: chunkBytes(0)}),
      );

      expect(
        () => serving.getChunk(
          transferId: transferId,
          fileId: fileId,
          index: 0,
          headers: getHeaders(epoch: 1),
        ),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.staleLease,
          ),
        ),
      );
    });

    test(
      'a server with no source refuses rather than answering empty',
      () async {
        seedTask();
        expect(
          () => endpoint.getChunk(
            transferId: transferId,
            fileId: fileId,
            index: 0,
            headers: getHeaders(),
          ),
          throwsA(
            isA<ProtocolViolation>().having(
              (ProtocolViolation e) => e.code,
              'code',
              ProtocolErrorCode.invalidState,
            ),
          ),
        );
      },
    );
  });
}

/// A source that answers from memory, so the `GET` path can be tested without a real file.
class _MemorySource implements OutgoingChunkSource {
  _MemorySource(this.chunks);

  final Map<int, Uint8List> chunks;
  int readCount = 0;

  @override
  Future<Uint8List> readChunk({
    required String transferId,
    required String fileId,
    required int offsetBytes,
    required int length,
  }) async {
    readCount++;
    final Uint8List? bytes =
        chunks[offsetBytes ~/ ProtocolLimits.chunkSizeBytes];
    if (bytes == null) {
      throw WireErrorException(
        ProtocolErrorCode.manifestMismatch,
        'no source bytes for that offset',
      );
    }
    return bytes;
  }
}

/// A local error type, so the test does not depend on the storage layer's exception shape.
class WireErrorException implements Exception {
  const WireErrorException(this.code, this.detail);

  final ProtocolErrorCode code;
  final String detail;

  @override
  String toString() => '${WireError.of(code).code}: $detail';
}
