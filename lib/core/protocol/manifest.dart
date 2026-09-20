/// Frozen manifest and the `LFTM1` digest, per `docs/protocol/v1.0-draft1.md` §5.
///
/// The manifest is frozen once the sender has prepared the files and the receiver
/// has accepted them. From that point it is the authority for what the two sides
/// are transferring: file identities, sizes, chunk counts and the per-file and
/// per-chunk digests. Its encoding is fixed byte-for-byte so that two independent
/// implementations agree on the digest, which is why §5.2 forbids hashing JSON
/// text or relying on a language's default serialization.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:nearsend/core/protocol/canonical_writer.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/protocol/relative_path.dart';

/// ASCII magic that prefixes the LFTM1 digest input, followed by a zero byte.
const String manifestMagic = 'LFTM1';

/// One file entry of a frozen manifest (§5).
class ManifestFile {
  const ManifestFile({
    required this.fileId,
    required this.relativePath,
    required this.sizeBytes,
    required this.chunkSizeBytes,
    required this.chunkCount,
    required this.fileSha256,
    required this.chunkManifestDigest,
  });

  /// Canonical lowercase UUID. §5 allows duplicate display paths but requires a
  /// distinct [fileId] for each entry.
  final String fileId;

  /// NFC-normalised relative path as produced by the sender (§5.1).
  final String relativePath;

  /// File size in bytes.
  final int sizeBytes;

  /// Fixed at [ProtocolLimits.chunkSizeBytes] for v1.0.
  final int chunkSizeBytes;

  /// `ceil(sizeBytes / chunkSizeBytes)`, zero for an empty file.
  final int chunkCount;

  /// SHA-256 of the raw file bytes, never of the concatenated chunk digests.
  final String fileSha256;

  /// LFTC1 digest of this file's chunk manifest.
  final String chunkManifestDigest;

  /// Builds an entry, validating every field and deriving [chunkCount].
  factory ManifestFile.create({
    required String fileId,
    required String relativePath,
    required int sizeBytes,
    required String fileSha256,
    required String chunkManifestDigest,
    int chunkSizeBytes = ProtocolLimits.chunkSizeBytes,
  }) {
    return ManifestFile(
      fileId: fileId,
      relativePath: relativePath,
      sizeBytes: sizeBytes,
      chunkSizeBytes: chunkSizeBytes,
      chunkCount: chunkCountForSize(sizeBytes, chunkSizeBytes),
      fileSha256: fileSha256,
      chunkManifestDigest: chunkManifestDigest,
    );
  }

  /// Parses one file entry, rejecting undefined or malformed fields (§4, §5).
  factory ManifestFile.fromJson(Map<String, Object?> json, int position) {
    final String scope = 'files[$position]';
    rejectUnknownKeys(json, _fileKeys, scope);

    final Object? fileId = requireField(json, 'fileId', scope);
    uuidToBytes(fileId, '$scope.fileId');

    final Object? path = requireField(json, 'relativePath', scope);
    if (path is! String) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidPath,
        '$scope.relativePath must be a string',
      );
    }
    RelativePathRules.validate(path);

    final int sizeBytes = parseDecimalString(
      requireField(json, 'sizeBytes', scope),
      '$scope.sizeBytes',
    );

    final int chunkSizeBytes = parseJsonInteger(
      requireField(json, 'chunkSizeBytes', scope),
      '$scope.chunkSizeBytes',
    );
    if (chunkSizeBytes != ProtocolLimits.chunkSizeBytes) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        '$scope.chunkSizeBytes must be ${ProtocolLimits.chunkSizeBytes} for '
        'protocol v1.0',
      );
    }

    final int declaredChunkCount = parseDecimalString(
      requireField(json, 'chunkCount', scope),
      '$scope.chunkCount',
    );
    final int derivedChunkCount = chunkCountForSize(sizeBytes, chunkSizeBytes);
    if (declaredChunkCount != derivedChunkCount) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        '$scope.chunkCount is $declaredChunkCount but the size requires '
        '$derivedChunkCount',
      );
    }

    final Object? fileSha = requireField(json, 'fileSha256', scope);
    sha256HexToBytes(fileSha, '$scope.fileSha256');

    final Object? chunkDigest = requireField(
      json,
      'chunkManifestDigest',
      scope,
    );
    sha256HexToBytes(chunkDigest, '$scope.chunkManifestDigest');

    return ManifestFile(
      fileId: fileId! as String,
      relativePath: path,
      sizeBytes: sizeBytes,
      chunkSizeBytes: chunkSizeBytes,
      chunkCount: declaredChunkCount,
      fileSha256: fileSha! as String,
      chunkManifestDigest: chunkDigest! as String,
    );
  }

  /// JSON form matching the specification's field names and types.
  Map<String, Object?> toJson() => <String, Object?>{
    'fileId': fileId,
    'relativePath': relativePath,
    // §4 makes byte counts decimal strings so that number formatting cannot
    // change the encoded bytes.
    'sizeBytes': sizeBytes.toString(),
    'chunkSizeBytes': chunkSizeBytes,
    'chunkCount': chunkCount.toString(),
    'fileSha256': fileSha256,
    'chunkManifestDigest': chunkManifestDigest,
  };

  static const Set<String> _fileKeys = <String>{
    'fileId',
    'relativePath',
    'sizeBytes',
    'chunkSizeBytes',
    'chunkCount',
    'fileSha256',
    'chunkManifestDigest',
  };
}

/// A manifest that both sides have accepted and may no longer change (§5, §6).
class FrozenManifest {
  const FrozenManifest({
    required this.protocolMajor,
    required this.protocolMinor,
    required this.transferId,
    required this.files,
  });

  final int protocolMajor;
  final int protocolMinor;
  final String transferId;

  /// Files in the logical order the user confirmed. §5 states that reordering the
  /// array changes the digest, while JSON key order and whitespace do not.
  final List<ManifestFile> files;

  /// Parses and fully validates a manifest body.
  factory FrozenManifest.fromJson(Map<String, Object?> json) {
    rejectUnknownKeys(json, _manifestKeys, 'manifest');

    final int major = parseJsonInteger(
      requireField(json, 'protocolMajor', 'manifest'),
      'manifest.protocolMajor',
    );
    final int minor = parseJsonInteger(
      requireField(json, 'protocolMinor', 'manifest'),
      'manifest.protocolMinor',
    );
    if (major != ProtocolLimits.protocolMajor ||
        minor != ProtocolLimits.protocolMinor) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'manifest protocol version $major.$minor is not supported by this '
        'implementation (${ProtocolLimits.protocolMajor}.'
        '${ProtocolLimits.protocolMinor})',
      );
    }

    final Object? transferId = requireField(json, 'transferId', 'manifest');
    uuidToBytes(transferId, 'manifest.transferId');

    final Object? files = requireField(json, 'files', 'manifest');
    if (files is! List) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'manifest.files must be an array',
      );
    }
    if (files.isEmpty || files.length > ProtocolLimits.maxFilesPerTransfer) {
      throw ProtocolViolation(
        ProtocolErrorCode.resourceLimit,
        'manifest.files must hold 1..${ProtocolLimits.maxFilesPerTransfer} '
        'entries, got ${files.length}',
      );
    }

    final List<ManifestFile> parsed = <ManifestFile>[];
    final Set<String> seenIds = <String>{};
    int totalChunks = 0;
    int totalBytes = 0;

    for (int position = 0; position < files.length; position++) {
      final Object? entry = files[position];
      if (entry is! Map) {
        throw ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'files[$position] must be an object',
        );
      }
      final ManifestFile file = ManifestFile.fromJson(
        entry.cast<String, Object?>(),
        position,
      );

      if (!seenIds.add(file.fileId)) {
        throw ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'files[$position] repeats fileId ${file.fileId}',
        );
      }

      totalChunks += file.chunkCount;
      if (totalChunks > ProtocolLimits.maxChunksPerTransfer) {
        throw ProtocolViolation(
          ProtocolErrorCode.resourceLimit,
          'manifest exceeds ${ProtocolLimits.maxChunksPerTransfer} chunks',
        );
      }

      totalBytes += file.sizeBytes;
      if (totalBytes > ProtocolLimits.maxDecimalValue) {
        // §4 requires the summed file size not to overflow signed 64-bit.
        throw const ProtocolViolation(
          ProtocolErrorCode.resourceLimit,
          'manifest total size overflows the signed 64-bit range',
        );
      }

      parsed.add(file);
    }

    return FrozenManifest(
      protocolMajor: major,
      protocolMinor: minor,
      transferId: transferId! as String,
      files: List<ManifestFile>.unmodifiable(parsed),
    );
  }

  /// Number of files.
  int get fileCount => files.length;

  /// Sum of every file's size.
  int get totalBytes =>
      files.fold<int>(0, (int sum, ManifestFile file) => sum + file.sizeBytes);

  /// Sum of every file's chunk count.
  int get totalChunks => files.fold<int>(
    0,
    (int count, ManifestFile file) => count + file.chunkCount,
  );

  /// Serialises back to the specification's JSON shape.
  Map<String, Object?> toJson() => <String, Object?>{
    'protocolMajor': protocolMajor,
    'protocolMinor': protocolMinor,
    'transferId': transferId,
    'files': <Map<String, Object?>>[
      for (final ManifestFile file in files) file.toJson(),
    ],
  };

  /// UTF-8 encoded JSON. Provided for transport and diagnostics; **never** hashed
  /// to produce [manifestDigest], which §5.2 defines over [canonicalBytes].
  Uint8List toUtf8Json() => utf8.encode(jsonEncode(toJson()));

  /// Builds the LFTM1 byte sequence (§5.2).
  ///
  /// `LFTM1` + `0x00`, `major:u16`, `minor:u16`, `transferId:16`,
  /// `fileCount:u32`, then per file `fileId:16`, `pathByteLength:u32`,
  /// `pathUTF8`, `size:u64`, `chunkSize:u32`, `chunkCount:u64`,
  /// `fileSha256:32`, `chunkManifestDigest:32`.
  Uint8List canonicalBytes() {
    final CanonicalWriter writer = CanonicalWriter();
    writer.ascii(manifestMagic);
    writer.u8(0);
    writer.u16(protocolMajor);
    writer.u16(protocolMinor);
    writer.raw(uuidToBytes(transferId, 'transferId'));
    writer.u32(files.length);

    for (final ManifestFile file in files) {
      writer.raw(uuidToBytes(file.fileId, 'fileId'));

      // §5.2 measures the path in UTF-8 bytes, not in code units or characters.
      final List<int> pathBytes = utf8.encode(file.relativePath);
      writer.u32(pathBytes.length);
      writer.raw(pathBytes);

      writer.u64(file.sizeBytes);
      writer.u32(file.chunkSizeBytes);
      writer.u64(file.chunkCount);
      writer.raw(sha256HexToBytes(file.fileSha256, 'fileSha256'));
      writer.raw(
        sha256HexToBytes(file.chunkManifestDigest, 'chunkManifestDigest'),
      );
    }

    return writer.toBytes();
  }

  /// `manifestDigest` — SHA-256 over [canonicalBytes], lowercase hexadecimal.
  String get manifestDigest =>
      bytesToSha256Hex(sha256.convert(canonicalBytes()).bytes);

  /// Recomputes the digest and compares it with an expected value (§6 seal).
  void verifyDigest(String expected) {
    final String actual = manifestDigest;
    if (actual != expected) {
      throw const ProtocolViolation(
        ProtocolErrorCode.manifestMismatch,
        'recomputed manifest digest does not match the frozen digest',
      );
    }
  }

  static const Set<String> _manifestKeys = <String>{
    'protocolMajor',
    'protocolMinor',
    'transferId',
    'files',
  };
}
