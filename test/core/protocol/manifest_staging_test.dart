import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/manifest_page.dart';
import 'package:nearsend/core/protocol/manifest_staging.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';

/// Assembling and sealing a manifest from pages (§6).
///
/// §6's rules are mostly about what a *retransmission* must do, which is the part a naive
/// implementation gets wrong: appending pages to a list passes a happy-path test and still
/// counts a duplicate page twice.
void main() {
  const String transferId = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';

  Matcher refuses = throwsA(isA<ProtocolViolation>());

  String uuid(int n) =>
      '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

  List<ChunkRecord> chunksFor(int sizeBytes) => <ChunkRecord>[
    for (
      int i = 0;
      i < chunkCountForSize(sizeBytes, ProtocolLimits.chunkSizeBytes);
      i++
    )
      ChunkRecord(
        index: i,
        length: chunkLengthForIndex(
          sizeBytes,
          ProtocolLimits.chunkSizeBytes,
          i,
        ),
        sha256: (i + 1).toRadixString(16).padLeft(64, '0'),
      ),
  ];

  ManifestFile file(int n, int sizeBytes) {
    final List<ChunkRecord> chunks = chunksFor(sizeBytes);
    return ManifestFile(
      fileId: uuid(n),
      relativePath: 'file-$n.bin',
      sizeBytes: sizeBytes,
      chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
      chunkCount: chunks.length,
      fileSha256: (n + 100).toRadixString(16).padLeft(64, '0'),
      chunkManifestDigest: ChunkManifestCodec.digest(
        chunks: chunks,
        sizeBytes: sizeBytes,
        chunkSizeBytes: ProtocolLimits.chunkSizeBytes,
      ),
    );
  }

  /// One file with one chunk, one file with two chunks, and one empty file.
  final List<ManifestFile> manifestFiles = <ManifestFile>[
    file(0, 4),
    file(1, ProtocolLimits.chunkSizeBytes + 4),
    file(2, 0),
  ];

  /// The digest the sender would have declared.
  final String manifestDigest = FrozenManifest(
    protocolMajor: ProtocolLimits.protocolMajor,
    protocolMinor: ProtocolLimits.protocolMinor,
    transferId: transferId,
    files: manifestFiles,
  ).manifestDigest;

  ManifestStaging staging() =>
      ManifestStaging(transferId: transferId, manifestDigest: manifestDigest);

  ManifestFilePage filesPage(int start, List<ManifestFile> items) =>
      ManifestFilePage(
        manifestDigest: manifestDigest,
        startIndex: start,
        items: items,
      );

  ManifestChunkPage chunksPage(
    String fileId,
    int start,
    List<ChunkRecord> items,
  ) => ManifestChunkPage(
    manifestDigest: manifestDigest,
    fileId: fileId,
    startIndex: start,
    items: items,
  );

  /// Stages every page a conforming sender would send.
  void stageEverything(ManifestStaging staging) {
    for (final ManifestFilePage page in ManifestPager.filePages(
      manifestDigest: manifestDigest,
      files: manifestFiles,
    )) {
      staging.addPage(page);
    }
    for (final ManifestFile f in manifestFiles) {
      for (final ManifestChunkPage page in ManifestPager.chunkPages(
        manifestDigest: manifestDigest,
        fileId: f.fileId,
        chunks: chunksFor(f.sizeBytes),
      )) {
        staging.addPage(page);
      }
    }
  }

  group('a complete manifest seals', () {
    test('and produces the frozen manifest the sender described', () {
      final ManifestStaging s = staging();
      stageEverything(s);

      final FrozenManifest frozen = s.seal();

      expect(s.isSealed, isTrue);
      expect(frozen.transferId, transferId);
      expect(
        frozen.files.map((ManifestFile f) => f.fileId).toList(),
        manifestFiles.map((ManifestFile f) => f.fileId).toList(),
      );
      expect(frozen.manifestDigest, manifestDigest);
    });

    test('sealing twice returns the same manifest rather than failing', () {
      final ManifestStaging s = staging();
      stageEverything(s);

      expect(identical(s.seal(), s.seal()), isTrue);
    });

    test('an empty file needs no chunk page', () {
      final ManifestStaging s = ManifestStaging(
        transferId: transferId,
        manifestDigest: FrozenManifest(
          protocolMajor: 1,
          protocolMinor: 0,
          transferId: transferId,
          files: <ManifestFile>[file(0, 0)],
        ).manifestDigest,
      );
      s.addPage(
        ManifestFilePage(
          manifestDigest: s.manifestDigest,
          startIndex: 0,
          items: <ManifestFile>[file(0, 0)],
        ),
      );

      expect(s.seal().files.single.chunkCount, 0);
    });
  });

  group('retransmission', () {
    test('the same page again is accepted and changes nothing', () {
      final ManifestStaging s = staging();
      final ManifestFilePage page = filesPage(0, manifestFiles);

      expect(s.addPage(page), PageAcceptance.stored);
      expect(
        s.addPage(page),
        PageAcceptance.alreadyStored,
        reason: '§6: 重传相同页返回成功; a lost response must be recoverable',
      );
    });

    test('a duplicate page does not inflate the count', () {
      final ManifestStaging s = staging();
      final ManifestFilePage page = filesPage(0, manifestFiles);

      s.addPage(page);
      final int afterFirst = s.stagedFileCount;
      s.addPage(page);
      s.addPage(page);

      expect(
        s.stagedFileCount,
        afterFirst,
        reason:
            '§6: 保存时按条目索引去重，不能用重复页增加累计数量; an implementation that '
            'appended pages would count these three times',
      );
      expect(s.stagedFileCount, 3);
    });

    test('an overlapping page with identical content is accepted', () {
      final ManifestStaging s = staging();
      s.addPage(
        filesPage(0, <ManifestFile>[manifestFiles[0], manifestFiles[1]]),
      );

      expect(
        s.addPage(
          filesPage(1, <ManifestFile>[manifestFiles[1], manifestFiles[2]]),
        ),
        PageAcceptance.stored,
        reason:
            '§6 rejects an overlapping range whose content *differs*; a retransmission '
            'that merely uses different boundaries is not a conflict',
      );
      expect(s.stagedFileCount, 3);
    });

    test('an overlapping page with different content is refused', () {
      final ManifestStaging s = staging();
      s.addPage(filesPage(0, <ManifestFile>[manifestFiles[0]]));

      expect(
        () => s.addPage(filesPage(0, <ManifestFile>[manifestFiles[1]])),
        refuses,
        reason: '§6: 重叠区间内容不一致拒绝',
      );
      expect(s.stagedFileCount, 1);
    });

    test('a conflicting chunk record is refused', () {
      final ManifestStaging s = staging();
      final ManifestFile f = manifestFiles[1];
      final List<ChunkRecord> chunks = chunksFor(f.sizeBytes);
      s.addPage(chunksPage(f.fileId, 0, chunks));

      final ChunkRecord altered = ChunkRecord(
        index: 0,
        length: chunks.first.length,
        sha256: 'f' * 64,
      );
      expect(
        () => s.addPage(chunksPage(f.fileId, 0, <ChunkRecord>[altered])),
        refuses,
      );
    });

    test('the same page for another file is not a duplicate', () {
      final ManifestStaging s = staging();
      final ManifestFile a = manifestFiles[0];
      final ManifestFile b = manifestFiles[1];
      s.addPage(chunksPage(a.fileId, 0, chunksFor(a.sizeBytes)));
      s.addPage(chunksPage(b.fileId, 0, chunksFor(b.sizeBytes)));

      expect(s.stagedChunkCount(a.fileId), 1);
      expect(s.stagedChunkCount(b.fileId), 2);
    });
  });

  group('order', () {
    test('pages may arrive out of order and still seal in index order', () {
      final ManifestStaging s = staging();
      // Files pages last, chunks pages first, and the files pages reversed.
      for (final ManifestFile f in manifestFiles) {
        s.addPage(chunksPage(f.fileId, 0, chunksFor(f.sizeBytes)));
      }
      for (final ManifestFilePage page in ManifestPager.filePages(
        manifestDigest: manifestDigest,
        files: manifestFiles,
      ).reversed) {
        s.addPage(page);
      }

      expect(
        s.seal().files.map((ManifestFile f) => f.fileId).toList(),
        manifestFiles.map((ManifestFile f) => f.fileId).toList(),
        reason:
            '§5 fixes the array as the logical order the user confirmed, and a page start '
            'index is what carries it',
      );
    });
  });

  group('seal refuses an incomplete or inconsistent manifest', () {
    test('a missing file page', () {
      final ManifestStaging s = staging();
      stageEverything(s);
      // Rebuild without the middle file to leave a gap.
      final ManifestStaging gapped = ManifestStaging(
        transferId: transferId,
        manifestDigest: manifestDigest,
      );
      gapped.addPage(
        filesPage(0, <ManifestFile>[manifestFiles[0], manifestFiles[2]]),
      );

      expect(() => gapped.seal(), refuses);
      expect(s.seal(), isNotNull, reason: 'the complete one still seals');
    });

    test('a gap leaves the manifest unsealed but readable', () {
      final ManifestStaging s = ManifestStaging(
        transferId: transferId,
        manifestDigest: manifestDigest,
      );
      // Index 0 and 2 present, 1 missing.
      s.addPage(filesPage(0, <ManifestFile>[manifestFiles[0]]));
      s.addPage(filesPage(2, <ManifestFile>[manifestFiles[2]]));

      expect(
        () => s.seal(),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.detail,
            'detail',
            contains('index 1 is missing'),
          ),
        ),
      );
      expect(s.isSealed, isFalse);
    });

    test('no file page at all', () {
      expect(() => staging().seal(), refuses);
    });

    test('a duplicated fileId', () {
      final ManifestStaging s = ManifestStaging(
        transferId: transferId,
        manifestDigest: FrozenManifest(
          protocolMajor: 1,
          protocolMinor: 0,
          transferId: transferId,
          files: <ManifestFile>[manifestFiles[0], manifestFiles[0]],
        ).manifestDigest,
      );
      s.addPage(
        ManifestFilePage(
          manifestDigest: s.manifestDigest,
          startIndex: 0,
          items: <ManifestFile>[manifestFiles[0], manifestFiles[0]],
        ),
      );

      expect(
        () => s.seal(),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.detail,
            'detail',
            contains('more than once'),
          ),
        ),
        reason: '§6: 重复 fileId……时 seal 失败',
      );
    });

    test('a missing chunk page', () {
      final ManifestStaging s = staging();
      final ManifestFile f = manifestFiles[1];
      s.addPage(filesPage(0, <ManifestFile>[f]));
      s.addPage(
        chunksPage(f.fileId, 0, <ChunkRecord>[chunksFor(f.sizeBytes)[0]]),
      );

      expect(
        () => s.seal(),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.detail,
            'detail',
            contains('chunk 1'),
          ),
        ),
        reason: '§6: 块数量……错误时 seal 失败',
      );
    });

    test('a chunk with the wrong length', () {
      final ManifestStaging s = staging();
      final ManifestFile f = manifestFiles[1];
      final List<ChunkRecord> chunks = chunksFor(f.sizeBytes);
      s.addPage(filesPage(0, <ManifestFile>[f]));
      s.addPage(
        chunksPage(f.fileId, 0, <ChunkRecord>[
          chunks[0],
          ChunkRecord(index: 1, length: 3, sha256: chunks[1].sha256),
        ]),
      );

      expect(
        () => s.seal(),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.detail,
            'detail',
            contains('declares 3 bytes'),
          ),
        ),
        reason:
            '§5.3 fixes the length from the file size, so a short chunk cannot be used to '
            'skip bytes',
      );
    });

    test('chunk pages for a file no file page declares', () {
      final ManifestStaging s = staging();
      s.addPage(filesPage(0, <ManifestFile>[manifestFiles[0]]));
      s.addPage(chunksPage(manifestFiles[0].fileId, 0, chunksFor(4)));
      s.addPage(chunksPage(uuid(9), 0, chunksFor(4)));

      expect(
        () => s.seal(),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.detail,
            'detail',
            contains('no file page declares'),
          ),
        ),
      );
    });

    test('a digest that disagrees with the assembled manifest', () {
      final ManifestStaging s = ManifestStaging(
        transferId: transferId,
        manifestDigest: 'f' * 64,
      );
      s.addPage(
        ManifestFilePage(
          manifestDigest: 'f' * 64,
          startIndex: 0,
          items: <ManifestFile>[file(0, 0)],
        ),
      );

      expect(
        () => s.seal(),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.manifestMismatch,
          ),
        ),
        reason:
            '§6: 总摘要不一致时 seal 失败; this is the check that makes a manifest which '
            'arrived in pieces equal to the one the sender described',
      );
      expect(s.isSealed, isFalse);
    });
  });

  group('after sealing', () {
    test('a page is refused', () {
      final ManifestStaging s = staging();
      stageEverything(s);
      s.seal();

      expect(
        () => s.addPage(filesPage(0, manifestFiles)),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.invalidState,
          ),
        ),
        reason: '§6: seal 后页不可修改',
      );
    });

    test('the sealed manifest is exposed', () {
      final ManifestStaging s = staging();
      expect(s.frozenManifest, isNull);
      stageEverything(s);
      s.seal();
      expect(s.frozenManifest, isNotNull);
    });
  });

  group('the staging window', () {
    test('runs from the first content, not from the offer', () {
      final ManifestStaging s = staging();
      expect(
        s.isExpired(nowMillis: 1 << 40),
        isFalse,
        reason: 'nothing has arrived, so there is no content to time out',
      );

      s.addPage(
        filesPage(0, <ManifestFile>[manifestFiles[0]]),
        nowMillis: 1000,
      );
      expect(s.firstContentAtMillis, 1000);

      final int windowMillis = ProtocolLimits.stagingTimeoutSeconds * 1000;
      expect(s.isExpired(nowMillis: 1000 + windowMillis - 1), isFalse);
      expect(s.isExpired(nowMillis: 1000 + windowMillis), isTrue);
    });

    test('a sealed manifest never expires', () {
      final ManifestStaging s = staging();
      stageEverything(s);
      s.seal();

      expect(
        s.isExpired(nowMillis: 1000 + 100000000),
        isFalse,
        reason: '§6: 不影响已经冻结的任务',
      );
    });
  });

  group('the transfer and digest are bound', () {
    test('an identifier that is not a UUID is refused', () {
      expect(
        () =>
            ManifestStaging(transferId: 'nope', manifestDigest: manifestDigest),
        refuses,
      );
    });

    test('a page carrying another digest is refused', () {
      final ManifestStaging s = staging();
      expect(
        () => s.addPage(
          ManifestFilePage(
            manifestDigest: 'f' * 64,
            startIndex: 0,
            items: <ManifestFile>[manifestFiles[0]],
          ),
        ),
        refuses,
      );
      expect(s.stagedFileCount, 0);
    });
  });
}
