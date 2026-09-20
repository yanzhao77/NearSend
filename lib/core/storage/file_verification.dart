/// Whole-file verification against the frozen manifest.
///
/// `APP_AND_SERVICE_DESIGN.md` §7: "全部 committed 后重新计算整文件摘要。摘要一致才允许导出。"
/// `SYSTEM_ARCHITECTURE.md` §6 step 8 puts the same check before export, and the recovery
/// flow (§6 恢复任务 step 3) re-checks local chunks and returns damaged ones to `missing`.
///
/// ## Why one streaming pass answers both questions
///
/// The receiver needs two different answers, and they are not the same question:
///
/// * **Is this file the file that was sent?** - the whole-file digest, and the gate on
///   export.
/// * **Which part is wrong?** - the per-chunk digests, because re-sending a 20 GiB file
///   to repair one bad block is not a recovery strategy.
///
/// Both come out of a single ordered read: each block is hashed for its own digest and
/// fed into the running whole-file digest at the same time. Reading twice would double
/// the I/O on the one path that runs over every byte the user received.
///
/// ## Bounded memory
///
/// Bytes are consumed as a stream and never accumulated: the only thing that grows is a
/// SHA-256 state. A caller that buffered the file to hash it would violate `AGENTS.md`
/// §2 rule 4, and at 20 GiB it would simply fail.
///
/// ## A damaged block is worse than a missing one
///
/// Protocol §5 allows `committedBytes` to fall, because a committed block that is wrong
/// would be trusted by every later recovery. So a block whose bytes do not match the
/// frozen manifest is demoted to `missing` here, in the one place that can prove it,
/// rather than being left for a resume to skip over.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_failure.dart';

/// The platform port that reads back staged chunk bytes.
///
/// Implementations must stream in order and must not return more or fewer bytes than the
/// chunk actually holds: verification treats a length that disagrees with the frozen
/// manifest as damage, which is the point. A short read is reported, never padded.
abstract class StagedChunkReader {
  /// Streams the staged bytes of one chunk, in order.
  ///
  /// Emits nothing when the chunk has no staged content at all, which verification
  /// reports as damage rather than as an empty chunk.
  Stream<Uint8List> read({required String fileId, required int index});
}

/// What verifying one file found.
class FileVerificationResult {
  const FileVerificationResult({
    required this.fileId,
    required this.expectedFileSha256,
    required this.computedFileSha256,
    required this.wholeFileDigestMatches,
    required this.damagedChunkIndices,
    required this.missingChunkIndices,
    required this.verifiedBytes,
    required this.expectedBytes,
  });

  final String fileId;

  /// The digest the frozen manifest and the sender agreed on.
  final String expectedFileSha256;

  /// The digest computed from the staged bytes.
  ///
  /// Meaningful only when [wholeFileDigestMatches] is not null; it is still filled in so
  /// a diagnostic can show how far off the data was.
  final String computedFileSha256;

  /// Whether the whole-file digest matched.
  ///
  /// **Null means "not computed"**, which is not the same as false: when a chunk is
  /// missing or damaged the digest is over incomplete or wrong data, so reporting a
  /// boolean would imply a comparison that cannot honestly be made. Export requires
  /// `true`, so null blocks export exactly as false does.
  final bool? wholeFileDigestMatches;

  /// Chunks whose staged bytes do not match the frozen manifest, ascending.
  final List<int> damagedChunkIndices;

  /// Chunks that are not committed, ascending.
  final List<int> missingChunkIndices;

  /// Bytes actually read from staging.
  final int verifiedBytes;

  /// Bytes the frozen manifest says the file has.
  final int expectedBytes;

  /// Whether every block is present and correct.
  bool get isComplete =>
      damagedChunkIndices.isEmpty && missingChunkIndices.isEmpty;

  /// Whether the file may be exported.
  ///
  /// Both conditions are required: complete blocks *and* a whole-file digest that was
  /// actually computed and matched. §7 gates export on the digest, not on the chunk
  /// count alone.
  bool get isExportable => isComplete && wholeFileDigestMatches == true;

  /// A short, non-sensitive summary for diagnostics and the UI.
  String get summary {
    if (isExportable) {
      return 'verified $verifiedBytes B, whole-file digest matches';
    }
    final List<String> reasons = <String>[
      if (missingChunkIndices.isNotEmpty)
        '${missingChunkIndices.length} chunk(s) not committed',
      if (damagedChunkIndices.isNotEmpty)
        '${damagedChunkIndices.length} chunk(s) failed their digest',
      if (wholeFileDigestMatches == false)
        'the whole-file digest does not match the frozen manifest',
    ];
    return reasons.isEmpty ? 'not verified' : reasons.join('; ');
  }

  @override
  String toString() =>
      'FileVerificationResult($fileId, exportable=$isExportable, '
      'damaged=$damagedChunkIndices, missing=$missingChunkIndices)';
}

/// Verifies staged bytes against the frozen manifest.
class FileVerifier {
  FileVerifier(this.database, {required this.reader, ChunkRepository? chunks})
    : chunks = chunks ?? ChunkRepository(database);

  final NearSendDatabase database;

  /// Where the staged bytes come from.
  final StagedChunkReader reader;

  /// Used to demote damaged blocks; the same instance the transfer path commits through.
  final ChunkRepository chunks;

  /// Verifies one file, and by default demotes the blocks that failed.
  ///
  /// Set [demoteDamagedChunks] to false for a read-only check; recovery screens the user
  /// with "正在检查已接收内容" before anything is written, and a dry run is also what a
  /// diagnostics view wants.
  Future<FileVerificationResult> verifyFile({
    required String fileId,
    bool demoteDamagedChunks = true,
  }) async {
    final _FrozenFile frozen = _readFrozenFile(fileId);
    final List<Row> rows = _readChunkRows(fileId, frozen.chunkCount);

    // The manifest is supposed to be internally consistent, because `registerFile`
    // refuses to store it otherwise. Re-checking here means verification never blames the
    // staged bytes for a manifest that cannot add up.
    int expectedTotal = 0;
    for (final Row row in rows) {
      expectedTotal += row['length_bytes'] as int;
    }
    if (expectedTotal != frozen.sizeBytes) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'file $fileId: the frozen chunk lengths sum to $expectedTotal but the file is '
        '${frozen.sizeBytes} bytes',
      );
    }

    final _DigestSink fileDigest = _DigestSink();
    final ByteConversionSink fileInput = sha256.startChunkedConversion(
      fileDigest,
    );

    final List<int> damaged = <int>[];
    final List<int> missing = <int>[];
    int verifiedBytes = 0;
    bool everyBlockReadCleanly = true;

    for (final Row row in rows) {
      final int index = row['idx'] as int;
      final int expectedLength = row['length_bytes'] as int;
      final String expectedChunkSha = (row['sha256'] as String).toLowerCase();

      if ((row['state'] as String) != ChunkState.committed.column) {
        missing.add(index);
        everyBlockReadCleanly = false;
        continue;
      }

      final _DigestSink chunkDigest = _DigestSink();
      final ByteConversionSink chunkInput = sha256.startChunkedConversion(
        chunkDigest,
      );

      int readBytes = 0;
      await for (final Uint8List part in reader.read(
        fileId: fileId,
        index: index,
      )) {
        if (part.isEmpty) {
          continue;
        }
        // Both digests see the same bytes in the same order, so the whole-file digest is
        // over exactly the concatenation the sender hashed.
        chunkInput.add(part);
        fileInput.add(part);
        readBytes += part.length;
      }
      chunkInput.close();

      verifiedBytes += readBytes;
      final bool lengthOk = readBytes == expectedLength;
      final bool digestOk = chunkDigest.value.toString() == expectedChunkSha;
      if (!lengthOk || !digestOk) {
        damaged.add(index);
        everyBlockReadCleanly = false;
      }
    }

    fileInput.close();
    final String computedFileSha = fileDigest.value.toString();

    // Only compare when every byte that the digest covers is known to be the right bytes.
    final bool? wholeFileMatches = everyBlockReadCleanly
        ? computedFileSha == frozen.fileSha256.toLowerCase()
        : null;

    if (demoteDamagedChunks && damaged.isNotEmpty) {
      chunks.markChunksMissing(fileId, damaged);
    }

    return FileVerificationResult(
      fileId: fileId,
      expectedFileSha256: frozen.fileSha256,
      computedFileSha256: computedFileSha,
      wholeFileDigestMatches: wholeFileMatches,
      damagedChunkIndices: List<int>.unmodifiable(damaged),
      missingChunkIndices: List<int>.unmodifiable(missing),
      verifiedBytes: verifiedBytes,
      expectedBytes: frozen.sizeBytes,
    );
  }

  _FrozenFile _readFrozenFile(String fileId) {
    final ResultSet rows = database.db.select(
      'SELECT size_bytes, chunk_count, file_sha256 FROM files WHERE file_id = ?;',
      <Object?>[fileId],
    );
    if (rows.isEmpty) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'file $fileId is not registered',
      );
    }
    final Row row = rows.first;
    return _FrozenFile(
      sizeBytes: row['size_bytes'] as int,
      chunkCount: row['chunk_count'] as int,
      fileSha256: row['file_sha256'] as String,
    );
  }

  List<Row> _readChunkRows(String fileId, int chunkCount) {
    final ResultSet rows = database.db.select(
      'SELECT idx, length_bytes, sha256, state FROM chunks WHERE file_id = ? '
      'ORDER BY idx;',
      <Object?>[fileId],
    );
    if (rows.length != chunkCount) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'file $fileId has ${rows.length} chunk rows but the frozen manifest declares '
        '$chunkCount',
      );
    }
    return <Row>[for (final Row row in rows) row];
  }
}

/// The frozen facts verification compares against.
class _FrozenFile {
  const _FrozenFile({
    required this.sizeBytes,
    required this.chunkCount,
    required this.fileSha256,
  });

  final int sizeBytes;
  final int chunkCount;
  final String fileSha256;
}

/// Collects the single [Digest] a chunked conversion produces on close.
class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
