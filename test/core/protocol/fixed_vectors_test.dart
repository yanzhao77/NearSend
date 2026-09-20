import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';

/// Compares this Dart implementation against the protocol's fixed vectors.
///
/// The vectors in `docs/protocol/vectors-v1.json` were produced by the Python
/// reference probe on Linux. `docs/PROJECT_LEDGER.md` D04 recorded that they still
/// needed an independent implementation to compare against, and `AGENTS.md` warns
/// against translating the reference line by line and calling the result
/// cross-language evidence. This encoder was written from
/// `docs/protocol/v1.0-draft1.md` §5.2/§5.3 — the byte layout, the magic values and
/// the length rules come from the specification text — and the vectors are used
/// here as an independent check on that reading.
///
/// A failure in this file means one of two things: this implementation misreads the
/// specification, or the specification is ambiguous. Both must be resolved in the
/// documents, not by adjusting the vectors.
void main() {
  final List<Map<String, Object?>> vectors = _loadVectors();

  test('the vector file exists and covers the required cases', () {
    expect(
      vectors,
      isNotEmpty,
      reason: 'docs/protocol/vectors-v1.json must exist and be non-empty',
    );
    final Set<String> names = vectors
        .map((Map<String, Object?> v) => v['name']! as String)
        .toSet();
    expect(
      names,
      containsAll(<String>['empty', 'abc_unicode', 'tail']),
      reason: 'empty file, Unicode path and short tail chunk are all required',
    );
  });

  group('fixed vectors reproduce byte for byte', () {
    for (final Map<String, Object?> vector in vectors) {
      final String name = vector['name']! as String;

      test('$name: canonical bytes and manifest digest', () {
        final FrozenManifest manifest = FrozenManifest.fromJson(
          (vector['manifest']! as Map).cast<String, Object?>(),
        );

        expect(
          _hex(manifest.canonicalBytes()),
          vector['canonicalHex'],
          reason: 'LFTM1 encoding of "$name" must match the fixed vector',
        );
        expect(
          manifest.manifestDigest,
          vector['manifestDigest'],
          reason: 'manifestDigest of "$name" must match the fixed vector',
        );
      });

      test('$name: chunk manifest digest', () {
        final FrozenManifest manifest = FrozenManifest.fromJson(
          (vector['manifest']! as Map).cast<String, Object?>(),
        );
        final ManifestFile file = manifest.files.single;

        final List<ChunkRecord> chunks = ChunkManifestCodec.fromJson(
          vector['chunks'],
          sizeBytes: file.sizeBytes,
          chunkSizeBytes: file.chunkSizeBytes,
        );

        expect(
          ChunkManifestCodec.digest(
            chunks: chunks,
            sizeBytes: file.sizeBytes,
            chunkSizeBytes: file.chunkSizeBytes,
          ),
          file.chunkManifestDigest,
          reason: 'LFTC1 digest of "$name" must match the fixed vector',
        );
      });
    }
  });

  group('the digest is over the binary encoding, not over JSON text', () {
    test('hashing the manifest JSON would give a different value', () {
      final Map<String, Object?> json = (vectors.first['manifest']! as Map)
          .cast<String, Object?>();
      final FrozenManifest manifest = FrozenManifest.fromJson(json);

      final String jsonDigest = sha256
          .convert(manifest.toUtf8Json())
          .toString();

      expect(
        jsonDigest,
        isNot(manifest.manifestDigest),
        reason: '§5.2 forbids deriving manifestDigest from JSON text',
      );
      expect(
        manifest.manifestDigest,
        vectors.first['manifestDigest'],
        reason: 'the canonical digest must still match the fixed vector',
      );
    });
  });

  group('JSON key order and whitespace do not change the digest', () {
    test('reordering keys and re-serialising preserves the digest', () {
      final Map<String, Object?> original = (vectors[1]['manifest']! as Map)
          .cast<String, Object?>();

      // Round-trip through text so key order and whitespace are genuinely different.
      final Map<String, Object?> reordered = Map<String, Object?>.fromEntries(
        original.entries.toList().reversed,
      );
      final String text = const JsonEncoder.withIndent('    ')
          .convert(reordered);
      final Map<String, Object?> reparsed = (jsonDecode(text) as Map)
          .cast<String, Object?>();

      expect(
        FrozenManifest.fromJson(reparsed).manifestDigest,
        FrozenManifest.fromJson(original).manifestDigest,
        reason: '§5 says key order and whitespace must not affect the digest',
      );
    });

    test('reordering the files array does change the digest', () {
      final Map<String, Object?> first = (vectors[0]['manifest']! as Map)
          .cast<String, Object?>();
      final Map<String, Object?> second = (vectors[1]['manifest']! as Map)
          .cast<String, Object?>();

      // The vectors deliberately reuse one fileId, so the second entry is given a
      // distinct id: §5 requires distinct ids, and the point of this test is the
      // effect of array order, not of identity.
      final Map<String, Object?> secondFile = Map<String, Object?>.from(
        (second['files']! as List).first! as Map,
      );
      secondFile['fileId'] = '00000000-0000-4000-8000-000000000003';

      Map<String, Object?> combined(List<Object?> files) => <String, Object?>{
        'protocolMajor': 1,
        'protocolMinor': 0,
        'transferId': first['transferId'],
        'files': files,
      };

      final Map<String, Object?> forwardEntry =
          ((first['files']! as List).first! as Map).cast<String, Object?>();
      final List<Object?> inOrder = <Object?>[forwardEntry, secondFile];
      final List<Object?> reversed = inOrder.reversed.toList();

      final String forward = FrozenManifest.fromJson(combined(inOrder))
          .manifestDigest;
      final String backward = FrozenManifest.fromJson(combined(reversed))
          .manifestDigest;

      expect(
        backward,
        isNot(forward),
        reason: '§5 says reordering the files array must change the digest',
      );
    });
  });

  group('chunk digest edge cases', () {
    test('an empty file has the digest of the zero-count LFTC1 sequence', () {
      final ManifestFile file = FrozenManifest.fromJson(
        (vectors.first['manifest']! as Map).cast<String, Object?>(),
      ).files.single;

      expect(file.sizeBytes, 0);
      expect(file.chunkCount, 0);
      expect(ChunkManifestCodec.digestOfEmptyFile(), file.chunkManifestDigest);
    });

    test('the tail vector has a full chunk followed by a short chunk', () {
      final FrozenManifest manifest = FrozenManifest.fromJson(
        (vectors.last['manifest']! as Map).cast<String, Object?>(),
      );
      final ManifestFile file = manifest.files.single;

      expect(file.sizeBytes, ProtocolLimits.chunkSizeBytes + 3);
      expect(file.chunkCount, 2);

      final List<ChunkRecord> chunks = ChunkManifestCodec.fromJson(
        vectors.last['chunks'],
        sizeBytes: file.sizeBytes,
        chunkSizeBytes: file.chunkSizeBytes,
      );
      expect(chunks.first.length, ProtocolLimits.chunkSizeBytes);
      expect(chunks.last.length, 3);
    });

    test('a file just over one chunk is exactly two chunks', () {
      expect(
        _chunkCount(ProtocolLimits.chunkSizeBytes + 1),
        2,
        reason: 'the boundary must round up, not truncate',
      );
      expect(_chunkCount(ProtocolLimits.chunkSizeBytes), 1);
      expect(_chunkCount(ProtocolLimits.chunkSizeBytes - 1), 1);
      expect(_chunkCount(1), 1);
      expect(_chunkCount(0), 0);
    });
  });
}

int _chunkCount(int sizeBytes) {
  // Exercised through the public model rather than a private helper, so the
  // boundary is checked on the same path production code uses.
  final ManifestFile file = ManifestFile.create(
    fileId: '00000000-0000-4000-8000-000000000002',
    relativePath: 'boundary.bin',
    sizeBytes: sizeBytes,
    fileSha256: _zeros64,
    chunkManifestDigest: _zeros64,
  );
  return file.chunkCount;
}

/// A well-formed placeholder digest; only its shape matters for these checks.
final String _zeros64 = '0'.padRight(ProtocolLimits.sha256HexLength, '0');

List<Map<String, Object?>> _loadVectors() {
  final File file = File('docs/protocol/vectors-v1.json');
  if (!file.existsSync()) {
    throw StateError(
      'docs/protocol/vectors-v1.json not found; run tests from the package root',
    );
  }
  final Object? decoded = jsonDecode(file.readAsStringSync(encoding: utf8));
  if (decoded is! List) {
    throw StateError('vectors-v1.json must contain a JSON array');
  }
  return decoded.cast<Map<String, Object?>>().toList(growable: false);
}

String _hex(Uint8List bytes) {
  final StringBuffer buffer = StringBuffer();
  for (final int byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
