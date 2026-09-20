/// Chunk manifest digest, `LFTC1`, per `docs/protocol/v1.0-draft1.md` §5.3.
///
/// The chunk manifest is what lets a receiver prove it holds the *right* bytes in
/// the *right* places before any file data moves. Its encoding is therefore fixed
/// byte-for-byte rather than derived from JSON text.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:nearsend/core/protocol/canonical_writer.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';

/// ASCII magic that prefixes the LFTC1 digest input, followed by a zero byte.
const String chunkManifestMagic = 'LFTC1';

/// One entry of the chunk manifest (§5.3).
class ChunkRecord {
  const ChunkRecord({
    required this.index,
    required this.length,
    required this.sha256,
  });

  /// Zero-based, consecutive and ascending within a file.
  final int index;

  /// Byte length of this chunk, equal to the length derived from the file size.
  final int length;

  /// Lowercase hexadecimal SHA-256 of the chunk's bytes.
  final String sha256;

  @override
  String toString() => 'ChunkRecord($index, $length, $sha256)';
}

/// Encodes and validates the chunk manifest.
abstract final class ChunkManifestCodec {
  /// Parses the `chunks` array of a frozen manifest.
  ///
  /// Every field is checked against the frozen file size and chunk size rather
  /// than trusted: §5.3 fixes the chunk lengths, so a peer cannot declare a short
  /// chunk to skip bytes, and cannot omit or duplicate an index.
  static List<ChunkRecord> fromJson(
    Object? json, {
    required int sizeBytes,
    required int chunkSizeBytes,
  }) {
    if (json is! List) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'chunks must be an array',
      );
    }

    final int expectedCount = chunkCountForSize(sizeBytes, chunkSizeBytes);
    if (json.length != expectedCount) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'chunks has ${json.length} entries but the file size requires '
        '$expectedCount',
      );
    }

    final List<ChunkRecord> records = <ChunkRecord>[];
    for (int position = 0; position < json.length; position++) {
      final Object? entry = json[position];
      if (entry is! Map) {
        throw ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'chunks[$position] must be an object',
        );
      }
      final Map<String, Object?> map = entry.cast<String, Object?>();
      rejectUnknownKeys(map, _chunkKeys, 'chunks[$position]');

      final int index = parseDecimalString(
        requireField(map, 'index', 'chunks[$position]'),
        'chunks[$position].index',
      );
      if (index != position) {
        throw ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'chunks[$position] declares index $index; entries must be '
          'consecutive and ascending from zero',
        );
      }

      final int length = parseJsonInteger(
        requireField(map, 'length', 'chunks[$position]'),
        'chunks[$position].length',
      );
      final int expectedLength = chunkLengthForIndex(
        sizeBytes,
        chunkSizeBytes,
        index,
      );
      if (length != expectedLength) {
        throw ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'chunks[$position].length is $length but the file size requires '
          '$expectedLength',
        );
      }

      final Object? digest = requireField(map, 'sha256', 'chunks[$position]');
      sha256HexToBytes(digest, 'chunks[$position].sha256');

      records.add(
        ChunkRecord(index: index, length: length, sha256: digest! as String),
      );
    }

    return records;
  }

  /// Builds the LFTC1 byte sequence (§5.3).
  ///
  /// `LFTC1` + `0x00` + `chunkCount:u64` + for each chunk
  /// `index:u64`, `length:u32`, `sha256:32`.
  static Uint8List canonicalBytes({
    required List<ChunkRecord> chunks,
    required int sizeBytes,
    required int chunkSizeBytes,
  }) {
    final CanonicalWriter writer = CanonicalWriter();
    writer.ascii(chunkManifestMagic);
    writer.u8(0);

    final int derivedCount = chunkCountForSize(sizeBytes, chunkSizeBytes);
    if (chunks.length != derivedCount) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'chunk count ${chunks.length} does not match the file size '
        '($derivedCount required)',
      );
    }
    writer.u64(chunks.length);

    for (int position = 0; position < chunks.length; position++) {
      final ChunkRecord chunk = chunks[position];
      if (chunk.index != position) {
        throw ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'chunk at position $position declares index ${chunk.index}',
        );
      }
      final int expectedLength = chunkLengthForIndex(
        sizeBytes,
        chunkSizeBytes,
        position,
      );
      if (chunk.length != expectedLength) {
        throw ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'chunk ${chunk.index} length ${chunk.length} does not match '
          '$expectedLength',
        );
      }

      writer.u64(chunk.index);
      writer.u32(chunk.length);
      writer.raw(sha256HexToBytes(chunk.sha256, 'chunk ${chunk.index} sha256'));
    }

    return writer.toBytes();
  }

  /// LFTC1 digest as lowercase hexadecimal.
  static String digest({
    required List<ChunkRecord> chunks,
    required int sizeBytes,
    required int chunkSizeBytes,
  }) {
    final Uint8List bytes = canonicalBytes(
      chunks: chunks,
      sizeBytes: sizeBytes,
      chunkSizeBytes: chunkSizeBytes,
    );
    return bytesToSha256Hex(sha256.convert(bytes).bytes);
  }

  /// The LFTC1 digest of a file with no chunks, used for zero-byte files (§5.3).
  static String digestOfEmptyFile() => digest(
    chunks: const <ChunkRecord>[],
    sizeBytes: 0,
    chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
  );

  static const Set<String> _chunkKeys = <String>{'index', 'length', 'sha256'};
}

/// Convenience for callers that hold only the JSON form.
extension ChunkManifestJson on List<ChunkRecord> {
  /// Encodes this list as the JSON array used in a manifest body.
  List<Map<String, Object?>> toJson() => <Map<String, Object?>>[
    for (final ChunkRecord chunk in this)
      <String, Object?>{
        'index': chunk.index.toString(),
        'length': chunk.length,
        'sha256': chunk.sha256,
      },
  ];

  /// UTF-8 encoded JSON, used when a caller needs a stable textual form.
  Uint8List toUtf8Json() => utf8.encode(jsonEncode(toJson()));
}
