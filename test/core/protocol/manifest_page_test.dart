import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/manifest_page.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';

/// Manifest pages and the pager (§6).
void main() {
  final String digest = 'a' * 64;
  final String fileId = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';

  Matcher refuses = throwsA(isA<ProtocolViolation>());

  /// A canonical lowercase UUID with [n] in the last group.
  String uuid(int n) =>
      '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

  ManifestFile file(int n, {String? path}) => ManifestFile(
    fileId: uuid(n),
    relativePath: path ?? 'file-$n.bin',
    sizeBytes: 4,
    chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
    chunkCount: 1,
    fileSha256: n.toRadixString(16).padLeft(64, '0'),
    chunkManifestDigest: 'b' * 64,
  );

  Map<String, Object?> filesPageJson({
    Object? manifestDigest,
    Object? kind = 'files',
    Object? fileIdValue,
    Object? startIndex = '0',
    Object? items,
  }) => <String, Object?>{
    'manifestDigest': manifestDigest ?? digest,
    'kind': kind,
    'fileId': ?fileIdValue,
    'startIndex': startIndex,
    'items': items ?? <Object?>[file(0).toJson()],
  };

  Map<String, Object?> chunksPageJson({
    Object? startIndex = '0',
    Object? items,
  }) => <String, Object?>{
    'manifestDigest': digest,
    'kind': 'chunks',
    'fileId': fileId,
    'startIndex': startIndex,
    'items':
        items ??
        <Object?>[
          <String, Object?>{'index': '0', 'length': 4, 'sha256': 'c' * 64},
        ],
  };

  group('parsing a files page', () {
    test('round trips', () {
      final ManifestPage page = ManifestPage.parse(filesPageJson());
      expect(page, isA<ManifestFilePage>());
      expect(page.startIndex, 0);
      expect(page.length, 1);

      final ManifestPage again = ManifestPage.parse(page.toJson());
      expect((again as ManifestFilePage).items.single.fileId, uuid(0));
    });

    test('carries no fileId', () {
      expect(
        ManifestPage.parse(filesPageJson()).toJson().containsKey('fileId'),
        isFalse,
      );
    });

    test('a fileId is refused', () {
      expect(
        () => ManifestPage.parse(filesPageJson(fileIdValue: fileId)),
        refuses,
        reason: '§6: files 页不得带 fileId',
      );
    });

    test('the item cap is 128', () {
      expect(
        ManifestPage.parse(
          filesPageJson(
            items: <Object?>[for (int i = 0; i < 128; i++) file(i).toJson()],
          ),
        ).length,
        128,
      );
      expect(
        () => ManifestPage.parse(
          filesPageJson(
            items: <Object?>[for (int i = 0; i < 129; i++) file(i).toJson()],
          ),
        ),
        refuses,
      );
    });

    test('an empty page is refused', () {
      expect(
        () => ManifestPage.parse(filesPageJson(items: <Object?>[])),
        refuses,
        reason: 'a page that carries nothing advances nothing',
      );
    });

    test('an entry is validated as a manifest file', () {
      expect(
        () => ManifestPage.parse(
          filesPageJson(
            items: <Object?>[
              <String, Object?>{'fileId': fileId},
            ],
          ),
        ),
        refuses,
      );
      expect(
        () => ManifestPage.parse(
          filesPageJson(
            items: <Object?>[
              <String, Object?>{...file(0).toJson(), 'extra': 'x'},
            ],
          ),
        ),
        refuses,
      );
    });
  });

  group('parsing a chunks page', () {
    test('round trips', () {
      final ManifestPage page = ManifestPage.parse(chunksPageJson());
      expect(page, isA<ManifestChunkPage>());
      expect((page as ManifestChunkPage).fileId, fileId);
      expect(page.items.single.index, 0);
      expect(page.items.single.length, 4);
    });

    test('a missing fileId is refused', () {
      final Map<String, Object?> json = chunksPageJson()..remove('fileId');
      expect(
        () => ManifestPage.parse(json),
        refuses,
        reason: '§6: chunks 页必须带 fileId',
      );
    });

    test('a fileId that is not a UUID is refused', () {
      expect(
        () => ManifestPage.parse(chunksPageJson()..['fileId'] = 'nope'),
        refuses,
      );
    });

    test('an item index must match its place in the page', () {
      expect(
        () => ManifestPage.parse(
          chunksPageJson(
            items: <Object?>[
              <String, Object?>{'index': '5', 'length': 4, 'sha256': 'c' * 64},
            ],
          ),
        ),
        refuses,
        reason:
            '§6 says a page covers a contiguous index range, so an index is not free: a '
            'page that skipped one would cover different bytes than it claims',
      );
    });

    test('a page starting later still expects consecutive indices', () {
      expect(
        ManifestPage.parse(
          chunksPageJson(
            startIndex: '10',
            items: <Object?>[
              <String, Object?>{'index': '10', 'length': 4, 'sha256': 'c' * 64},
              <String, Object?>{'index': '11', 'length': 4, 'sha256': 'c' * 64},
            ],
          ),
        ).startIndex,
        10,
      );
      expect(
        () => ManifestPage.parse(
          chunksPageJson(
            startIndex: '10',
            items: <Object?>[
              <String, Object?>{'index': '10', 'length': 4, 'sha256': 'c' * 64},
              <String, Object?>{'index': '30', 'length': 4, 'sha256': 'c' * 64},
            ],
          ),
        ),
        refuses,
      );
    });

    test('the item cap is 1024', () {
      List<Object?> items(int n) => <Object?>[
        for (int i = 0; i < n; i++)
          <String, Object?>{'index': '$i', 'length': 4, 'sha256': 'c' * 64},
      ];
      expect(
        ManifestPage.parse(chunksPageJson(items: items(1024))).length,
        1024,
      );
      expect(
        () => ManifestPage.parse(chunksPageJson(items: items(1025))),
        refuses,
      );
    });
  });

  group('page fields are validated', () {
    test('an unknown kind is refused', () {
      expect(() => ManifestPage.parse(filesPageJson(kind: 'chunk')), refuses);
    });

    test('an unknown field is refused', () {
      expect(
        () => ManifestPage.parse(filesPageJson()..['nextIndex'] = '1'),
        refuses,
      );
    });

    test('a digest that is not a SHA-256 is refused', () {
      expect(
        () => ManifestPage.parse(filesPageJson(manifestDigest: 'ABC')),
        refuses,
      );
      expect(
        () => ManifestPage.parse(filesPageJson(manifestDigest: 'A' * 64)),
        refuses,
        reason: 'the digest is lowercase hexadecimal',
      );
    });

    test('startIndex is a decimal string', () {
      expect(
        () => ManifestPage.parse(filesPageJson(startIndex: '01')),
        refuses,
      );
      expect(() => ManifestPage.parse(filesPageJson(startIndex: 0)), refuses);
      expect(
        () => ManifestPage.parse(filesPageJson(startIndex: '-1')),
        refuses,
      );
    });
  });

  group('the pager', () {
    test('splits files at the item cap', () {
      final List<ManifestFilePage> pages = ManifestPager.filePages(
        manifestDigest: digest,
        files: <ManifestFile>[for (int i = 0; i < 300; i++) file(i)],
      );

      expect(pages, hasLength(3));
      expect(pages[0].length, 128);
      expect(pages[1].length, 128);
      expect(pages[2].length, 44);
    });

    test('pages cover every index exactly once, in order', () {
      final List<ManifestFilePage> pages = ManifestPager.filePages(
        manifestDigest: digest,
        files: <ManifestFile>[for (int i = 0; i < 300; i++) file(i)],
      );

      int expected = 0;
      for (final ManifestFilePage page in pages) {
        expect(page.startIndex, expected);
        expected = page.endIndex;
      }
      expect(expected, 300);
    });

    test('splits chunks at the item cap', () {
      final List<ManifestChunkPage> pages = ManifestPager.chunkPages(
        manifestDigest: digest,
        fileId: fileId,
        chunks: <ChunkRecord>[
          for (int i = 0; i < 2050; i++)
            ChunkRecord(index: i, length: 4, sha256: 'c' * 64),
        ],
      );

      expect(pages, hasLength(3));
      expect(pages[0].length, 1024);
      expect(pages[2].length, 2);
    });

    test('a list that fits produces one page', () {
      expect(
        ManifestPager.filePages(
          manifestDigest: digest,
          files: <ManifestFile>[file(0)],
        ),
        hasLength(1),
      );
    });

    test('every page parses back', () {
      final List<ManifestFilePage> pages = ManifestPager.filePages(
        manifestDigest: digest,
        files: <ManifestFile>[for (int i = 0; i < 200; i++) file(i)],
      );
      for (final ManifestFilePage page in pages) {
        expect(ManifestPage.parse(page.toJson()), isA<ManifestFilePage>());
      }
    });
  });

  group('the byte bound is measured, not estimated', () {
    // §5.1 caps a path at 1024 UTF-8 bytes, so a real entry cannot approach 1 MiB and the
    // item cap is what actually binds. These tests drive the mechanism directly, with
    // entries the pager could never be handed by a conforming sender, so the guard is
    // exercised rather than assumed.
    final String hugePath =
        'é' * 700000; // 1,400,000 bytes, over the control body cap on its own
    final ManifestFile huge = file(0, path: hugePath);

    test('a page shrinks below the item cap to stay within 1 MiB', () {
      final ManifestFile medium = file(
        1,
        path: 'é' * 300000,
      ); // ~600 KB, so two will not fit

      final List<ManifestFilePage> pages = ManifestPager.filePages(
        manifestDigest: digest,
        files: <ManifestFile>[
          medium,
          file(2, path: 'é' * 300000),
        ],
      );

      expect(
        pages,
        hasLength(2),
        reason:
            'two 600 KB entries cannot share a 1 MiB page, so the byte bound - not the '
            '128 item cap - decides',
      );
      for (final ManifestFilePage page in pages) {
        expect(
          ManifestPager.encodedSize(page),
          lessThanOrEqualTo(ProtocolLimits.controlBodyMaxBytes),
        );
      }
    });

    test(
      'an entry that cannot fit at all is refused rather than looped over',
      () {
        expect(
          () => ManifestPager.filePages(
            manifestDigest: digest,
            files: <ManifestFile>[huge],
          ),
          throwsA(
            isA<ProtocolViolation>().having(
              (ProtocolViolation e) => e.code,
              'code',
              ProtocolErrorCode.resourceLimit,
            ),
          ),
        );
      },
    );

    test('a page of the largest allowed path still fits', () {
      // The realistic worst case: 128 entries each with a 1024 byte path, where the path
      // is made of three-byte characters so a character count would understate it.
      final String worstPath = '中' * 341; // 1023 bytes, just under §5.1's cap
      expect(utf8.encode(worstPath).length, lessThanOrEqualTo(1024));

      final List<ManifestFilePage> pages = ManifestPager.filePages(
        manifestDigest: digest,
        files: <ManifestFile>[
          for (int i = 0; i < 128; i++) file(i, path: worstPath),
        ],
      );

      expect(
        pages,
        hasLength(1),
        reason:
            'the item cap binds here: 128 entries at the largest legal path are still '
            'under the control body limit',
      );
      expect(
        ManifestPager.encodedSize(pages.single),
        lessThan(ProtocolLimits.controlBodyMaxBytes),
      );
    });

    test('the largest legal chunk page fits too', () {
      final List<ManifestChunkPage> pages = ManifestPager.chunkPages(
        manifestDigest: digest,
        fileId: fileId,
        chunks: <ChunkRecord>[
          for (int i = 0; i < ProtocolLimits.chunkPageLimit; i++)
            ChunkRecord(index: i, length: 4194304, sha256: 'c' * 64),
        ],
      );
      expect(pages, hasLength(1));
      expect(
        ManifestPager.encodedSize(pages.single),
        lessThan(ProtocolLimits.controlBodyMaxBytes),
      );
    });
  });

  group('page identity', () {
    test('coverage and overlap are by index range', () {
      final ManifestPage a = ManifestFilePage(
        manifestDigest: digest,
        startIndex: 0,
        items: <ManifestFile>[file(0), file(1)],
      );
      final ManifestPage b = ManifestFilePage(
        manifestDigest: digest,
        startIndex: 1,
        items: <ManifestFile>[file(1), file(2)],
      );
      final ManifestPage c = ManifestFilePage(
        manifestDigest: digest,
        startIndex: 2,
        items: <ManifestFile>[file(2)],
      );

      expect(a.covers(0), isTrue);
      expect(a.covers(2), isFalse);
      expect(a.overlaps(b), isTrue);
      expect(a.overlaps(c), isFalse);
      expect(b.overlaps(a), isTrue);
    });
  });
}
