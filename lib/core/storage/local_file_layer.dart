/// The platform storage ports, implemented over `dart:io`.
///
/// ## Why one implementation covers Windows and Android staging
///
/// §5.1 is explicit that a manifest's `relativePath` is metadata and "不直接拼接成可写路径",
/// and `AGENTS.md` §9 warns that a SAF URI, an iOS security-scoped resource and a Windows
/// storage handle are not all plain paths. The consequence for staging is that it never needs
/// to be a user-visible location: it is the application's own working copy, so it lives under a
/// directory this process owns and is reached by a normal path on every platform. That is why
/// there is one [StagingFileSink] rather than three.
///
/// What genuinely differs per platform is where a **source** comes from and where an
/// **export** goes, because those are the user's files. Those are separate ports
/// ([SourceFileProvider] and `ExportSink`), and the Android implementation of the first is
/// backed by a SAF platform channel.
///
/// ## The streaming rules this file has to keep
///
/// `AGENTS.md` §2 rule 4: "不把整文件读入内存。使用流式读写、有界缓冲和背压". So:
///
/// * a chunk is written at its offset and flushed to disk before the sink returns, because
///   `DurableChunkSink`'s contract is that the bytes are durable when it answers;
/// * the whole-file digest is computed by streaming the file once, in `chunkSizeBytes` reads,
///   never by holding a copy;
/// * nothing here reads a file's bytes into a single buffer, and nothing copies a whole file
///   into a cache first.
///
/// ## Durability, stated honestly
///
/// `RandomAccessFile.flush` is `fsync` on the platforms this build targets, and that is what
/// §8's "durable sync" asks for. Whether it really survives a power cut on a given device is
/// B04's real-hardware question and is **not** claimed here: what is claimed is that the
/// application asked the platform to sync and committed to SQLite only after it said yes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/export_service.dart';
import 'package:nearsend/core/storage/file_verification.dart';
import 'package:nearsend/core/storage/storage_failure.dart';

/// Where the application keeps its own working copies.
///
/// ## Why staging is one file per chunk rather than one file per transfer file
///
/// The obvious design writes every chunk into a single `<fileId>.part` at its offset. It does
/// not work in Dart, and the reason is worth recording because it was found by a test rather
/// than by inspection: `dart:io` has **no mode that opens an existing file for writing without
/// truncating it**. `FileMode.write`, `writeOnly` and `writeOnlyAppend` all either truncate or
/// force writes to the end, so a second chunk opened the file with `writeOnly` and erased the
/// first chunk's bytes - the staged file came back as zeros.
///
/// A single handle held open for a whole session would work around that and break the other
/// requirement: §9 wants a transfer to resume after a process restart, and a re-opened
/// truncating handle would discard every committed chunk's bytes while the database still
/// called them `committed`. That is precisely the "committed but wrong" state §8 and
/// `AGENTS.md` §2 rule 5 exist to prevent.
///
/// One file per chunk removes the problem at the root: each part file is written once, in full,
/// by exactly one writer, so truncating it is correct; and a part file that is already correct
/// survives a restart untouched, because nothing ever opens it for writing again. The cost is
/// more directory entries - one per chunk, which for a 20 GiB file is 5120 - and that is the
/// trade this build makes, deliberately and visibly.
class LocalStagingLayout {
  const LocalStagingLayout(this.root);

  /// An application-private directory. Never a user-chosen one: §5.1 keeps a manifest path
  /// away from the filesystem, and staging is not something the user should meet.
  final Directory root;

  /// The directory holding one transfer file's chunks.
  ///
  /// Keyed by `fileId`, which the protocol validates as a canonical UUID, so an arriving
  /// relative path has no way to reach the filesystem through this name.
  Directory fileDirectory(String fileId) => Directory(
    '${root.path}${Platform.pathSeparator}staging'
    '${Platform.pathSeparator}$fileId',
  );

  /// The file holding exactly one chunk's bytes.
  File chunkFile(String fileId, int index) =>
      File('${fileDirectory(fileId).path}${Platform.pathSeparator}$index.part');

  /// Ensures the staging directory exists.
  Future<void> prepare() async {
    final Directory staging = Directory(
      '${root.path}${Platform.pathSeparator}staging',
    );
    if (!staging.existsSync()) {
      await staging.create(recursive: true);
    }
  }
}

/// Writes a chunk to its own file and makes it durable before answering.
class StagingFileSink implements DurableChunkSink {
  StagingFileSink(this.layout);

  final LocalStagingLayout layout;

  @override
  Future<DurableChunkWriteResult> writeVerifyAndSync({
    required String fileId,
    required int index,
    required int offsetBytes,
    required Uint8List bytes,
  }) async {
    final File target = layout.chunkFile(fileId, index);
    RandomAccessFile? handle;
    try {
      final Directory parent = target.parent;
      if (!parent.existsSync()) {
        await parent.create(recursive: true);
      }
      // Truncating is correct here and only here: this file holds one chunk, written once in
      // full, and a re-sent chunk is meant to replace it.
      handle = await target.open(mode: FileMode.writeOnly);
      await handle.writeFrom(bytes);
      // §8: the bytes must be durable before the caller may commit a chunk row. `flush` is the
      // platform's fsync, and the repository commits only after this returns.
      await handle.flush();
    } on FileSystemException catch (error) {
      throw StorageException(
        StorageFailureCode.commitFailed,
        'staging write for $fileId[$index] failed',
        cause: error,
      );
    } finally {
      await handle?.close();
    }

    return DurableChunkWriteResult(
      lengthBytes: bytes.length,
      sha256: sha256.convert(bytes).toString(),
    );
  }

  /// Removes a file's staging chunks. Silently succeeds when there are none.
  ///
  /// Only ever called for app-internal staging, and only after the export record is durable.
  Future<void> deleteStaging(String fileId) async {
    final Directory dir = layout.fileDirectory(fileId);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  /// Whether any chunk of [fileId] is staged, which is what makes a resume worth attempting.
  bool hasStaging(String fileId) {
    final Directory dir = layout.fileDirectory(fileId);
    if (!dir.existsSync()) {
      return false;
    }
    return dir.listSync().any((FileSystemEntity e) => e is File);
  }
}

/// Streams a staged file's chunks in order, for whole-file verification.
class StagingChunkReader implements StagedChunkReader {
  StagingChunkReader(this.layout);

  final LocalStagingLayout layout;

  @override
  Stream<Uint8List> read({required String fileId, required int index}) async* {
    final File part = layout.chunkFile(fileId, index);
    if (!part.existsSync()) {
      // Emitting nothing is what verification reads as damage; padding would hide it.
      return;
    }
    final RandomAccessFile handle = await part.open();
    try {
      final int length = await part.length();
      int remaining = length;
      while (remaining > 0) {
        final int want = remaining < 256 * 1024 ? remaining : 256 * 1024;
        final Uint8List piece = await handle.read(want);
        if (piece.isEmpty) {
          return;
        }
        remaining -= piece.length;
        yield piece;
      }
    } finally {
      await handle.close();
    }
  }
}

/// A file the user chose to send, and the bytes it had when it was chosen.
class SourceFilePlan {
  const SourceFilePlan({
    required this.file,
    required this.manifest,
    required this.chunks,
  });

  /// The source the reader opens. A normal path for a desktop or app-private file; a SAF URI
  /// is resolved by the platform implementation of [SourceFileProvider] before it gets here.
  final File file;

  /// The manifest entry, whose digests were computed by streaming the source once.
  final ManifestFile manifest;

  /// The chunk records, in order.
  final List<ChunkRecord> chunks;

  @override
  String toString() => 'SourceFilePlan(${manifest.relativePath})';
}

/// Reads a chosen source file in bounded pieces and describes it (§5.2, §5.3).
///
/// The manifest has to be built **before** anything is sent, and §5.2 hashes the raw file
/// bytes, so this is a full pass over the source. It is a streaming pass: the only thing that
/// grows is the running SHA-256 state and one chunk at a time.
class LocalSourceReader {
  const LocalSourceReader();

  /// Plans one source file.
  ///
  /// [relativePath] is what the manifest will carry and what the receiver records; the bytes
  /// are read from [source] regardless, so a display name never decides which file is opened.
  Future<SourceFilePlan> plan({
    required File source,
    required String relativePath,
    required String fileId,
  }) async {
    final int sizeBytes = await source.length();
    final int chunkCount = chunkCountForSize(
      sizeBytes,
      ProtocolLimits.chunkSizeBytes,
    );

    final List<ChunkRecord> chunks = <ChunkRecord>[];
    final RandomAccessFile handle = await source.open();
    try {
      // One pass, one chunk in memory at a time, and one whole-file digest over the same
      // bytes: computing them in two passes would read the file twice for no gain.
      final _StreamingFileDigest whole = _StreamingFileDigest();
      for (int index = 0; index < chunkCount; index++) {
        final int length = chunkLengthForIndex(
          sizeBytes,
          ProtocolLimits.chunkSizeBytes,
          index,
        );
        final Uint8List bytes = await _readExactly(handle, length);
        if (bytes.length != length) {
          throw ProtocolViolation(
            ProtocolErrorCode.sourceChanged,
            'the source changed while it was being read: chunk $index has '
            '${bytes.length} bytes but the file length requires $length',
          );
        }
        whole.add(bytes);
        chunks.add(
          ChunkRecord(
            index: index,
            length: length,
            sha256: sha256.convert(bytes).toString(),
          ),
        );
      }

      final String fileSha256 = whole.close();
      return SourceFilePlan(
        file: source,
        manifest: ManifestFile(
          fileId: fileId,
          relativePath: relativePath,
          sizeBytes: sizeBytes,
          chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
          chunkCount: chunkCount,
          fileSha256: fileSha256,
          chunkManifestDigest: ChunkManifestCodec.digest(
            chunks: chunks,
            sizeBytes: sizeBytes,
            chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
          ),
        ),
        chunks: List<ChunkRecord>.unmodifiable(chunks),
      );
    } finally {
      await handle.close();
    }
  }

  /// Streams one chunk of [plan] to [onChunk], in index order, with real backpressure.
  ///
  /// The consumer is awaited before the next read happens, so a slow network cannot make this
  /// buffer chunks: at most one chunk exists at a time. That is `AGENTS.md` §2 rule 4's
  /// backpressure requirement, and it is why this takes a callback rather than returning a
  /// stream that a caller could drain eagerly.
  Future<void> streamChunks({
    required SourceFilePlan plan,
    required Future<void> Function(int index, Uint8List bytes) onChunk,
  }) async {
    final RandomAccessFile handle = await plan.file.open();
    try {
      for (final ChunkRecord record in plan.chunks) {
        final Uint8List bytes = await _readExactly(handle, record.length);
        if (bytes.length != record.length) {
          throw ProtocolViolation(
            ProtocolErrorCode.sourceChanged,
            'the source changed while it was being sent: chunk ${record.index} has '
            '${bytes.length} bytes but the manifest requires ${record.length}',
          );
        }
        // Re-checked against the manifest, not against the earlier pass: a source that changed
        // between planning and sending must be refused rather than delivered under a digest
        // that no longer describes it (§11's SOURCE_CHANGED).
        if (sha256.convert(bytes).toString() != record.sha256) {
          throw ProtocolViolation(
            ProtocolErrorCode.sourceChanged,
            'the source changed while it was being sent: chunk ${record.index} no longer '
            'matches the digest the manifest declares',
          );
        }
        await onChunk(record.index, bytes);
      }
    } finally {
      await handle.close();
    }
  }

  /// Reads exactly [length] bytes, or fewer at end of file.
  ///
  /// A single `read` may return less than asked for even mid-file, so this loops; treating a
  /// short read as end-of-file would silently truncate a chunk.
  static Future<Uint8List> _readExactly(
    RandomAccessFile handle,
    int length,
  ) async {
    if (length == 0) {
      return Uint8List(0);
    }
    final BytesBuilder builder = BytesBuilder(copy: false);
    int remaining = length;
    while (remaining > 0) {
      final Uint8List part = await handle.read(remaining);
      if (part.isEmpty) {
        break;
      }
      builder.add(part);
      remaining -= part.length;
    }
    return builder.takeBytes();
  }
}

/// A running whole-file SHA-256 over bytes fed to it in order.
///
/// Uses a small local sink rather than the `convert` package's `AccumulatorSink`, so that no
/// dependency is added for a four-line `add`/`close` pair; `AGENTS.md` §5 requires a new
/// dependency to be justified, and this one could not be.
class _StreamingFileDigest {
  final _SingleDigestSink _sink = _SingleDigestSink();
  late final ByteConversionSink _input = sha256.startChunkedConversion(_sink);

  void add(List<int> bytes) => _input.add(bytes);

  String close() {
    _input.close();
    return _sink.digest.toString();
  }
}

/// Collects the one digest a chunked SHA-256 conversion produces.
class _SingleDigestSink implements Sink<Digest> {
  Digest? _digest;

  Digest get digest {
    final Digest? value = _digest;
    if (value == null) {
      throw StateError('the digest sink was read before it was closed');
    }
    return value;
  }

  @override
  void add(Digest data) => _digest = data;

  @override
  void close() {}
}

/// Writes the user's copy into a directory this process can open by path.
///
/// This is the desktop and app-private implementation of [ExportSink]. A document provider
/// (Android SAF) cannot be reached by path and gets its own implementation; the port is what
/// keeps that difference out of the export orchestration.
///
/// ## The atomicity it can and cannot promise
///
/// A same-filesystem rename is atomic, so the file appears under its final name complete or
/// not at all; a cross-filesystem move is not, and a document provider generally cannot be
/// either. The port reports which one happened rather than assuming the better one, because
/// V2.1 §15 requires the difference to be visible.
class LocalDirectoryExportSink implements ExportSink {
  LocalDirectoryExportSink({required this.layout, this.staging});

  final LocalStagingLayout layout;

  /// The staging handle, so `deleteStaging` can actually remove the copy.
  StagingFileSink? staging;

  /// Directory the user chose, per call. The service passes the same `targetRef` it recorded.
  @override
  Future<TargetInventory> inventory({required String targetRef}) async {
    final Directory target = Directory(targetRef);
    try {
      if (!target.existsSync()) {
        return TargetInventory.known(const <TargetEntry>[]);
      }
      final List<TargetEntry> entries = <TargetEntry>[];
      await for (final FileSystemEntity entity in target.list(
        followLinks: false,
      )) {
        if (entity is! File) {
          entries.add(TargetEntry(path: entity.uri.pathSegments.last));
          continue;
        }
        entries.add(
          TargetEntry(
            path: entity.uri.pathSegments.last,
            sizeBytes: await entity.length(),
          ),
        );
      }
      return TargetInventory.known(entries);
    } on FileSystemException {
      // §8: an inventory that cannot be taken must be reported as unknown, never as empty -
      // the two lead to opposite decisions about whether it is safe to write.
      return TargetInventory.unknown();
    }
  }

  @override
  Future<ExportCommitResult> commit({
    required String fileId,
    required String targetRef,
    required String safePath,
  }) async {
    final Directory parts = layout.fileDirectory(fileId);
    if (!parts.existsSync()) {
      throw StorageException(
        StorageFailureCode.commitFailed,
        'the staging chunks for $fileId are gone, so there is nothing to export',
      );
    }
    final Directory target = Directory(targetRef);
    if (!target.existsSync()) {
      await target.create(recursive: true);
    }

    // The safe name comes from the naming policy, and this sink is the last thing between it and
    // the filesystem, so the shape is re-checked here rather than trusted: an absolute name or a
    // `..` segment would write outside the directory the user chose, and §5.1's "路径必须规范化
    // 并防止绝对路径、`..` 穿越" is exactly this rule. The first attempt at this sink interpolated
    // the name straight into a path and failed on a nested name - which is how the missing check
    // was found.
    final List<String> segments = safePath
        .split(RegExp(r'[\\/]+'))
        .where((String s) => s.isNotEmpty)
        .toList();
    if (segments.isEmpty ||
        segments.any((String s) => s == '.' || s == '..') ||
        safePath.startsWith('/') ||
        safePath.startsWith(r'\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(safePath)) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'the export name is not a plain name inside the chosen target; refusing to write it',
      );
    }

    final Directory destinationDirectory = segments.length == 1
        ? target
        : Directory(
            '${target.path}${Platform.pathSeparator}'
            '${segments.sublist(0, segments.length - 1).join(Platform.pathSeparator)}',
          );
    if (!destinationDirectory.existsSync()) {
      // Created only *under* the target the user chose, after the segments above were checked, so
      // this cannot become a way out of it.
      await destinationDirectory.create(recursive: true);
    }
    final File destination = File(
      '${destinationDirectory.path}${Platform.pathSeparator}${segments.last}',
    );
    if (destination.existsSync()) {
      // The naming policy already chose a free name; a file appearing here means something
      // else wrote it in between. Refusing is the only answer that cannot destroy it.
      throw StorageException(
        StorageFailureCode.commitFailed,
        'the target name is no longer free; refusing to overwrite an existing entry',
      );
    }

    final File temp = File('${destination.path}.nearsend-part');
    try {
      // Assembled by streaming the part files in index order, in bounded pieces. Nothing here
      // holds a whole file, which is `AGENTS.md` §2 rule 4's requirement - and the reason this
      // is not a `copy` of one big staging file is that there is no one big staging file.
      final List<File> ordered = _orderedParts(parts);
      final RandomAccessFile output = await temp.open(mode: FileMode.writeOnly);
      try {
        final Uint8List buffer = Uint8List(1024 * 1024);
        for (final File part in ordered) {
          final RandomAccessFile input = await part.open();
          try {
            while (true) {
              final int read = await input.readInto(buffer);
              if (read <= 0) {
                break;
              }
              await output.writeFrom(buffer, 0, read);
            }
          } finally {
            await input.close();
          }
        }
        await output.flush();
      } finally {
        await output.close();
      }

      final bool sameVolume = _sameVolume(temp.path, destination.path);
      await temp.rename(destination.path);
      return ExportCommitResult(atomic: sameVolume);
    } on FileSystemException catch (error) {
      if (temp.existsSync()) {
        try {
          await temp.delete();
        } on FileSystemException {
          // Best effort: leaving a `.nearsend-part` costs space and nothing else, and the
          // final name was never created, so the user's file was not touched.
        }
      }
      throw StorageException(
        StorageFailureCode.commitFailed,
        'writing the export failed',
        cause: error,
      );
    }
  }

  /// The chunk part files in numeric order.
  ///
  /// Sorted numerically rather than lexically: `10.part` sorts before `2.part` as a string, and
  /// assembling in the wrong order would produce a file whose bytes are all present and in the
  /// wrong places - a corruption that no length check would catch.
  static List<File> _orderedParts(Directory parts) {
    final List<MapEntry<int, File>> indexed = <MapEntry<int, File>>[];
    for (final FileSystemEntity entity in parts.listSync()) {
      if (entity is! File) {
        continue;
      }
      final String name = entity.uri.pathSegments.last;
      if (!name.endsWith('.part')) {
        continue;
      }
      final int? index = int.tryParse(name.substring(0, name.length - 5));
      if (index == null) {
        // An unexpected name means something else wrote into staging; refusing is better than
        // assembling a file whose contents are not what the manifest describes.
        throw StorageException(
          StorageFailureCode.commitFailed,
          'unexpected entry in staging: refusing to assemble a file from unknown parts',
        );
      }
      indexed.add(MapEntry<int, File>(index, entity));
    }
    indexed.sort(
      (MapEntry<int, File> a, MapEntry<int, File> b) => a.key.compareTo(b.key),
    );
    return <File>[for (final MapEntry<int, File> e in indexed) e.value];
  }

  @override
  Future<void> deleteStaging({required String fileId}) async {
    await (staging ?? StagingFileSink(layout)).deleteStaging(fileId);
  }

  /// Whether two paths are on the same filesystem, which is what makes a rename atomic.
  ///
  /// Compared by the volume root rather than by string prefix: on Windows the root is the drive
  /// letter, and on POSIX it is `/`. A wrong answer here would only mis-report atomicity, which
  /// is a claim rather than a behaviour, but §8's honesty rule makes it worth getting right.
  static bool _sameVolume(String a, String b) =>
      _rootOf(File(a).absolute.path) == _rootOf(File(b).absolute.path);

  static String _rootOf(String path) {
    final String normalized = path.replaceAll('\\', '/');
    final int colon = normalized.indexOf(':');
    if (colon >= 0) {
      return normalized.substring(0, colon + 1).toLowerCase();
    }
    return '/';
  }
}
