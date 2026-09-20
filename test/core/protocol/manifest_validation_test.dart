import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/protocol/relative_path.dart';

/// Negative and boundary cases for the canonical manifest.
///
/// `AGENTS.md` requires protocol changes to be checked against empty files, tail
/// chunks, offsets beyond 4 GiB, Unicode names, field ordering, duplicated or
/// missing chunks, and malformed input. Ordering is covered in
/// `fixed_vectors_test.dart`; everything else that must be *rejected* is here.
void main() {
  group('decimal strings (§4)', () {
    test('accepts zero and the maximum signed 64-bit value', () {
      expect(parseDecimalString('0', 'f'), 0);
      expect(parseDecimalString('1', 'f'), 1);
      expect(
        parseDecimalString('9223372036854775807', 'f'),
        ProtocolLimits.maxDecimalValue,
      );
    });

    test('rejects leading zeros, signs, exponents and whitespace', () {
      for (final String bad in <String>[
        '00',
        '01',
        '+1',
        '-1',
        '1e3',
        ' 1',
        '1 ',
        '',
        '1.0',
        '0x10',
      ]) {
        expect(
          () => parseDecimalString(bad, 'f'),
          throwsA(_violation(ProtocolErrorCode.invalidDecimal)),
          reason: '"$bad" must be rejected',
        );
      }
    });

    test('rejects more than 19 digits and values past 2^63-1', () {
      expect(
        () => parseDecimalString('12345678901234567890', 'f'),
        throwsA(_violation(ProtocolErrorCode.invalidDecimal)),
      );
    });

    test('a 19-digit value above 2^63-1 is refused, not crashed on', () {
      // The band that matters: §4's pattern allows nineteen digits, so these values are
      // well-shaped and reach the range check. `int.parse` answers them with a raw
      // `FormatException`, which would escape as an unhandled platform error where §4
      // requires `INVALID_DECIMAL` - and a peer chooses the value. The earlier 20-digit
      // case never reached the parser, which is why this one is separate.
      for (final String value in <String>[
        '9223372036854775808', // 2^63, one past the maximum
        '9999999999999999999', // the largest 19-digit value
        '9223372036854775907', // above the maximum with a different low digit
      ]) {
        expect(
          () => parseDecimalString(value, 'f'),
          throwsA(_violation(ProtocolErrorCode.invalidDecimal)),
          reason: '"$value" is nineteen digits and out of range',
        );
      }
    });

    test('the maximum itself still parses, so the boundary is exact', () {
      expect(
        parseDecimalString('9223372036854775807', 'f'),
        ProtocolLimits.maxDecimalValue,
      );
      expect(
        () => parseDecimalString('9223372036854775808', 'f'),
        throwsA(_violation(ProtocolErrorCode.invalidDecimal)),
      );
    });

    test('rejects non-string values, including JSON numbers', () {
      for (final Object? bad in <Object?>[0, 1, true, null, <int>[]]) {
        expect(
          () => parseDecimalString(bad, 'f'),
          throwsA(_violation(ProtocolErrorCode.invalidDecimal)),
          reason: '$bad must not be accepted as a decimal string',
        );
      }
    });
  });

  group('chunk arithmetic at and beyond 4 GiB', () {
    test('chunk count and offsets stay exact for a 20 GiB file', () {
      const int twentyGiB = 20 * 1024 * 1024 * 1024;
      const int chunkSize = ProtocolLimits.chunkSizeBytes;

      final int count = chunkCountForSize(twentyGiB, chunkSize);
      expect(count, 5120);
      expect(count * chunkSize, twentyGiB);

      // The last chunk of an exactly-divisible file is a full chunk.
      expect(chunkLengthForIndex(twentyGiB, chunkSize, count - 1), chunkSize);

      // A chunk index beyond 4 GiB must produce an offset beyond 4 GiB without
      // overflow, using 64-bit arithmetic.
      final int highIndex = count - 1;
      expect(
        chunkOffsetForIndex(twentyGiB, chunkSize, highIndex),
        twentyGiB - chunkSize,
      );
      expect(
        chunkOffsetForIndex(twentyGiB, chunkSize, highIndex),
        greaterThan(0xFFFFFFFF),
        reason: 'the offset must exceed the 32-bit range',
      );
    });

    test('the last chunk of a non-divisible large file is short', () {
      const int size = 20 * 1024 * 1024 * 1024 + 7;
      const int chunkSize = ProtocolLimits.chunkSizeBytes;
      final int count = chunkCountForSize(size, chunkSize);
      expect(chunkLengthForIndex(size, chunkSize, count - 1), 7);
    });

    test('an out-of-range index is refused rather than wrapped', () {
      expect(
        () => chunkLengthForIndex(
          ProtocolLimits.chunkSizeBytes,
          ProtocolLimits.chunkSizeBytes,
          1,
        ),
        throwsA(_violation(ProtocolErrorCode.invalidField)),
      );
      expect(
        () => chunkOffsetForIndex(0, ProtocolLimits.chunkSizeBytes, 0),
        throwsA(_violation(ProtocolErrorCode.invalidField)),
      );
    });
  });

  group('relative path rules (§5.1)', () {
    test('accepts ordinary and nested names', () {
      for (final String good in <String>[
        'a.txt',
        'dir/a.txt',
        'deep/nested/dir/file.bin',
        '资料/测试.txt',
        'name with spaces.txt',
        'archive.tar.gz',
      ]) {
        expect(RelativePathRules.validate(good), good);
      }
    });

    test('rejects traversal, absolute paths and illegal separators', () {
      for (final String bad in <String>[
        '/etc/passwd',
        'a/../../b',
        '../a',
        '..',
        '.',
        'a/./b',
        'a//b',
        'a/',
        '/',
        r'a\b',
        r'C:\temp\x',
        'dir:name',
      ]) {
        expect(
          () => RelativePathRules.validate(bad),
          throwsA(_violation(ProtocolErrorCode.invalidPath)),
          reason: '"$bad" must be rejected',
        );
      }
    });

    test('rejects control characters and characters Windows forbids', () {
      for (final String bad in <String>[
        'a\u0000b',
        'a\nb',
        'a\tb',
        'a\u007Fb',
        'a<b',
        'a>b',
        'a"b',
        'a|b',
        'a?b',
        'a*b',
      ]) {
        expect(
          () => RelativePathRules.validate(bad),
          throwsA(_violation(ProtocolErrorCode.invalidPath)),
          reason: 'must reject ${jsonEncode(bad)}',
        );
      }
    });

    test('rejects reserved device names, with or without an extension', () {
      for (final String bad in <String>[
        'CON',
        'con',
        'Con.txt',
        'NUL',
        'nul.bin',
        'COM1',
        'lpt9.dat',
        'dir/AUX',
      ]) {
        expect(
          () => RelativePathRules.validate(bad),
          throwsA(_violation(ProtocolErrorCode.invalidPath)),
          reason: '"$bad" must be rejected as a reserved name',
        );
      }
    });

    test('rejects segments ending in a space or a dot', () {
      for (final String bad in <String>['a ', 'a.', 'dir/b ', 'dir/b.']) {
        expect(
          () => RelativePathRules.validate(bad),
          throwsA(_violation(ProtocolErrorCode.invalidPath)),
        );
      }
    });

    test('rejects unpaired surrogates, which are not valid UTF-8', () {
      for (final String bad in <String>['a\uD800b', '\uDC00', 'x\uD83D']) {
        expect(
          () => RelativePathRules.validate(bad),
          throwsA(_violation(ProtocolErrorCode.invalidPath)),
          reason: 'lone surrogates must be rejected, not replaced with U+FFFD',
        );
      }
    });

    test('accepts a well-formed surrogate pair (non-BMP character)', () {
      // U+1F600 encoded as a surrogate pair must survive validation.
      expect(RelativePathRules.validate('emoji-\u{1F600}.txt'), isNotEmpty);
    });

    test('enforces the 1..1024 UTF-8 byte bound, not a character count', () {
      final String ascii1024 = 'a' * 1024;
      expect(RelativePathRules.validate(ascii1024).length, 1024);

      expect(
        () => RelativePathRules.validate('a' * 1025),
        throwsA(_violation(ProtocolErrorCode.invalidPath)),
      );
      expect(
        () => RelativePathRules.validate(''),
        throwsA(_violation(ProtocolErrorCode.invalidPath)),
      );

      // 342 three-byte characters are 1026 UTF-8 bytes: within the character
      // count a naive check would allow, but over the byte limit.
      final String multiByteOver = '资' * 342;
      expect(multiByteOver.length, 342);
      expect(
        () => RelativePathRules.validate(multiByteOver),
        throwsA(_violation(ProtocolErrorCode.invalidPath)),
        reason: 'the bound is measured in UTF-8 bytes (§5.1)',
      );
    });

    test('records that NFC enforcement is not yet implemented', () {
      // §5.1 requires the receiver to reject a non-NFC path. Implementing that
      // needs a Unicode normalisation package, which is a dependency decision
      // ADR-0001 leaves unfrozen. The gap is asserted here so that it cannot be
      // forgotten: a decomposed path currently passes validation.
      expect(
        RelativePathRules.enforcesNfcNormalisation,
        isFalse,
        reason:
            'If this becomes true, update docs/PROJECT_LEDGER.md §5 and the '
            'NFC row in the T02-01 task card',
      );
      // "e" + U+0301 is canonically equivalent to U+00E9 but is not its NFC form.
      expect(RelativePathRules.validate('cafe\u0301.txt'), isNotEmpty);
    });
  });

  group('manifest field validation', () {
    test('rejects an undefined field (§4)', () {
      final Map<String, Object?> json = _validManifest();
      json['unexpected'] = 1;
      expect(
        () => FrozenManifest.fromJson(json),
        throwsA(_violation(ProtocolErrorCode.invalidField)),
      );
    });

    test('rejects a missing field', () {
      final Map<String, Object?> json = _validManifest();
      json.remove('transferId');
      expect(
        () => FrozenManifest.fromJson(json),
        throwsA(_violation(ProtocolErrorCode.invalidField)),
      );
    });

    test('rejects an unsupported protocol version', () {
      for (final Map<String, Object?> patch in <Map<String, Object?>>[
        <String, Object?>{'protocolMajor': 2},
        <String, Object?>{'protocolMinor': 1},
      ]) {
        expect(
          () => FrozenManifest.fromJson(<String, Object?>{
            ..._validManifest(),
            ...patch,
          }),
          throwsA(_violation(ProtocolErrorCode.invalidField)),
        );
      }
    });

    test('rejects a non-canonical UUID', () {
      for (final String bad in <String>[
        '00000000-0000-4000-8000-00000000000',
        '00000000-0000-4000-8000-00000000000Z',
        '00000000000040008000000000000001',
        '00000000-0000-4000-8000-0000000000AB',
      ]) {
        final Map<String, Object?> json = _validManifest();
        json['transferId'] = bad;
        expect(
          () => FrozenManifest.fromJson(json),
          throwsA(_violation(ProtocolErrorCode.invalidField)),
          reason: '"$bad" must be rejected',
        );
      }
    });

    test('rejects a digest that is not 64 lowercase hex characters', () {
      for (final String bad in <String>[
        'abc',
        'A'.padRight(64, 'A'),
        'g'.padRight(64, 'g'),
        '0'.padRight(63, '0'),
      ]) {
        final Map<String, Object?> json = _validManifest();
        _file(json)['fileSha256'] = bad;
        expect(
          () => FrozenManifest.fromJson(json),
          throwsA(_violation(ProtocolErrorCode.invalidField)),
          reason: 'sha256 "$bad" must be rejected',
        );
      }
    });

    test('rejects a chunk size other than the v1.0 value', () {
      final Map<String, Object?> json = _validManifest();
      _file(json)['chunkSizeBytes'] = ProtocolLimits.chunkSizeBytes * 2;
      expect(
        () => FrozenManifest.fromJson(json),
        throwsA(_violation(ProtocolErrorCode.invalidField)),
      );
    });

    test('rejects chunkCount that disagrees with the size', () {
      final Map<String, Object?> json = _validManifest();
      _file(json)['chunkCount'] = '5';
      expect(
        () => FrozenManifest.fromJson(json),
        throwsA(_violation(ProtocolErrorCode.invalidField)),
      );
    });

    test('rejects a duplicated fileId (§5)', () {
      final Map<String, Object?> json = _validManifest();
      final List<Object?> files = json['files']! as List<Object?>;
      files.add(Map<String, Object?>.from(files.first! as Map));
      expect(
        () => FrozenManifest.fromJson(json),
        throwsA(_violation(ProtocolErrorCode.invalidField)),
        reason: 'each entry needs a distinct fileId even with the same path',
      );
    });

    test('rejects an empty files array and an oversized one', () {
      final Map<String, Object?> empty = _validManifest();
      empty['files'] = <Object?>[];
      expect(
        () => FrozenManifest.fromJson(empty),
        throwsA(_violation(ProtocolErrorCode.resourceLimit)),
      );

      final Map<String, Object?> tooMany = _validManifest();
      tooMany['files'] = <Object?>[
        for (int i = 0; i <= ProtocolLimits.maxFilesPerTransfer; i++)
          Map<String, Object?>.from(_file(_validManifest())),
      ];
      expect(
        () => FrozenManifest.fromJson(tooMany),
        throwsA(_violation(ProtocolErrorCode.resourceLimit)),
      );
    });

    test('accepts exactly the maximum file count when ids differ', () {
      final Map<String, Object?> json = _validManifest();
      json['files'] = <Object?>[
        for (int i = 1; i <= ProtocolLimits.maxFilesPerTransfer; i++)
          <String, Object?>{
            'fileId': _uuid(i),
            'relativePath': 'f$i.bin',
            'sizeBytes': '0',
            'chunkSizeBytes': ProtocolLimits.chunkSizeBytes,
            'chunkCount': '0',
            'fileSha256': _emptySha256,
            'chunkManifestDigest': ChunkManifestCodec.digestOfEmptyFile(),
          },
      ];
      final FrozenManifest manifest = FrozenManifest.fromJson(json);
      expect(manifest.fileCount, ProtocolLimits.maxFilesPerTransfer);
      expect(manifest.totalBytes, 0);
      expect(manifest.totalChunks, 0);
    });
  });

  group('chunk manifest rejection (§5.3)', () {
    test('rejects a missing chunk', () {
      expect(
        () => ChunkManifestCodec.fromJson(
          <Object?>[_chunk(0, 3)],
          sizeBytes: 6,
          chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
        ),
        throwsA(_violation(ProtocolErrorCode.invalidField)),
      );
    });

    test('rejects a duplicated index', () {
      expect(
        () => ChunkManifestCodec.fromJson(
          <Object?>[_chunk(0, 3), _chunk(0, 3)],
          sizeBytes: 6,
          chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
        ),
        throwsA(_violation(ProtocolErrorCode.invalidField)),
      );
    });

    test('rejects an out-of-order index', () {
      expect(
        () => ChunkManifestCodec.fromJson(
          <Object?>[_chunk(1, 3), _chunk(0, 3)],
          sizeBytes: 6,
          chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
        ),
        throwsA(_violation(ProtocolErrorCode.invalidField)),
      );
    });

    test('rejects a declared length that disagrees with the file size', () {
      expect(
        () => ChunkManifestCodec.fromJson(
          <Object?>[_chunk(0, 2), _chunk(1, 4)],
          sizeBytes: 5,
          chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
        ),
        throwsA(_violation(ProtocolErrorCode.invalidField)),
        reason: 'a peer must not be able to shorten a chunk to skip bytes',
      );
    });

    test('rejects a short chunk that is not the final one', () {
      expect(
        () => ChunkManifestCodec.fromJson(
          <Object?>[_chunk(0, 3), _chunk(1, 3)],
          sizeBytes: ProtocolLimits.chunkSizeBytes + 3,
          chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
        ),
        throwsA(_violation(ProtocolErrorCode.invalidField)),
        reason: 'only the last chunk may be short',
      );
    });

    test('rejects an undefined field in a chunk record', () {
      final Map<String, Object?> chunk = _chunk(0, 3);
      chunk['offset'] = 0;
      expect(
        () => ChunkManifestCodec.fromJson(
          <Object?>[chunk],
          sizeBytes: 3,
          chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
        ),
        throwsA(_violation(ProtocolErrorCode.invalidField)),
      );
    });

    test('rejects a chunk count that does not match the file size', () {
      expect(
        () => ChunkManifestCodec.fromJson(
          <Object?>[],
          sizeBytes: 1,
          chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
        ),
        throwsA(_violation(ProtocolErrorCode.invalidField)),
      );
    });
  });

  group('digest mismatch is reported as a protocol violation', () {
    test('verifyDigest refuses a different expected value', () {
      final FrozenManifest manifest = FrozenManifest.fromJson(_validManifest());
      expect(
        () => manifest.verifyDigest(_zeros64),
        throwsA(_violation(ProtocolErrorCode.manifestMismatch)),
      );
      expect(
        () => manifest.verifyDigest(manifest.manifestDigest),
        returnsNormally,
      );
    });
  });

  group('round trip', () {
    test('toJson parses back to the same manifest and digest', () {
      final FrozenManifest original = FrozenManifest.fromJson(_validManifest());
      final Object? roundTripped = jsonDecode(
        utf8.decode(original.toUtf8Json()),
      );
      final FrozenManifest reparsed = FrozenManifest.fromJson(
        (roundTripped! as Map).cast<String, Object?>(),
      );

      expect(reparsed.fileCount, original.fileCount);
      expect(reparsed.totalBytes, original.totalBytes);
      expect(reparsed.manifestDigest, original.manifestDigest);
      expect(_hex(reparsed.canonicalBytes()), _hex(original.canonicalBytes()));
    });
  });
}

final String _emptySha256 =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
final String _zeros64 = '0'.padRight(ProtocolLimits.sha256HexLength, '0');

String _uuid(int value) =>
    '00000000-0000-4000-8000-${value.toString().padLeft(12, '0')}';

Map<String, Object?> _validManifest() => <String, Object?>{
  'protocolMajor': 1,
  'protocolMinor': 0,
  'transferId': '00000000-0000-4000-8000-000000000001',
  'files': <Object?>[_fileEntry('empty.bin', 0, 0)],
};

Map<String, Object?> _file(Map<String, Object?> manifest) =>
    (manifest['files']! as List<Object?>).first! as Map<String, Object?>;

Map<String, Object?> _fileEntry(String path, int sizeBytes, int chunkCount) =>
    <String, Object?>{
      'fileId': '00000000-0000-4000-8000-000000000002',
      'relativePath': path,
      'sizeBytes': sizeBytes.toString(),
      'chunkSizeBytes': ProtocolLimits.chunkSizeBytes,
      'chunkCount': chunkCount.toString(),
      'fileSha256': _emptySha256,
      'chunkManifestDigest': ChunkManifestCodec.digestOfEmptyFile(),
    };

Map<String, Object?> _chunk(int index, int length) => <String, Object?>{
  'index': index.toString(),
  'length': length,
  'sha256': _zeros64,
};

Matcher _violation(ProtocolErrorCode code) => isA<ProtocolViolation>().having(
  (ProtocolViolation e) => e.code,
  'code',
  code,
);

String _hex(Uint8List bytes) {
  final StringBuffer buffer = StringBuffer();
  for (final int byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
