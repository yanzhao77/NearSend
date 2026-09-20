/// Manifest pages, `docs/protocol/v1.0-draft1.md` §6.
///
/// §6 fixes the shape and the bounds:
///
/// > 文件页最大 128 项，块页最大 1024 项，**并同时受 1 MiB 上限约束**。
/// > 页结构 {manifestDigest,kind,fileId?,startIndex,items}；startIndex 是十进制字符串，
/// > files 页不得带 fileId，chunks 页必须带 fileId。
/// > 每页覆盖连续索引区间……
///
/// ## The bound that is easy to miss
///
/// The item cap is the bound people remember; the byte cap is the one that actually
/// protects the control body. A page of 128 file entries is comfortably under 1 MiB, but
/// the two limits are independent, so [ManifestPager] fills greedily and then **encodes the
/// page to check it**, rather than trusting an estimate. §5.1 allows a path of up to 1024
/// UTF-8 bytes, and a path of multi-byte characters is where an estimate that counted
/// characters instead of bytes would come apart.
///
/// ## Why the pages are a sealed type
///
/// A page is one of exactly two shapes and they are not interchangeable: a files page has
/// no `fileId` and a chunks page must have one, and their items are different records. A
/// single class with an optional field would let a files page carry a `fileId` and a chunks
/// page omit one, which §6 forbids and which the type can simply refuse instead.
library;

import 'dart:convert';

import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';

/// One page of a manifest upload (§6).
sealed class ManifestPage {
  const ManifestPage({required this.manifestDigest, required this.startIndex});

  /// The digest the whole manifest must have once sealed.
  final String manifestDigest;

  /// The index of the first item, as a protocol decimal value.
  final int startIndex;

  /// How many items this page carries.
  int get length;

  /// The index just past this page's last item.
  int get endIndex => startIndex + length;

  /// Whether [index] falls inside this page.
  bool covers(int index) => index >= startIndex && index < endIndex;

  /// Whether [other] overlaps this page's index range.
  bool overlaps(ManifestPage other) =>
      other.startIndex < endIndex && startIndex < other.endIndex;

  /// The wire form, §6's `{manifestDigest,kind,fileId?,startIndex,items}`.
  Map<String, Object?> toJson();

  /// Parses a page body, rejecting anything §6 does not allow.
  static ManifestPage parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _pageKeys, 'the manifest page');

    final Object? digest = requireField(
      json,
      'manifestDigest',
      'the manifest page',
    );
    sha256HexToBytes(digest, 'manifestDigest');

    final int startIndex = parseDecimalString(
      requireField(json, 'startIndex', 'the manifest page'),
      'startIndex',
    );

    final Object? kind = requireField(json, 'kind', 'the manifest page');
    if (kind is! String) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the manifest page kind must be a string',
      );
    }

    final Object? items = requireField(json, 'items', 'the manifest page');
    if (items is! List) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the manifest page items must be an array',
      );
    }

    switch (kind) {
      case 'files':
        if (json.containsKey('fileId')) {
          throw const ProtocolViolation(
            ProtocolErrorCode.invalidField,
            'a files page must not carry a fileId',
          );
        }
        _assertWithinLimits(
          items.length,
          ProtocolLimits.filePageLimit,
          'a files page',
        );
        return ManifestFilePage(
          manifestDigest: digest! as String,
          startIndex: startIndex,
          items: List<ManifestFile>.unmodifiable(<ManifestFile>[
            for (int i = 0; i < items.length; i++)
              ManifestFile.fromJson(_objectAt(items, i, 'files'), i),
          ]),
        );

      case 'chunks':
        final Object? fileId = requireField(
          json,
          'fileId',
          'the manifest page',
        );
        uuidToBytes(fileId, 'fileId');
        _assertWithinLimits(
          items.length,
          ProtocolLimits.chunkPageLimit,
          'a chunks page',
        );
        return ManifestChunkPage(
          manifestDigest: digest! as String,
          fileId: fileId! as String,
          startIndex: startIndex,
          items: List<ChunkRecord>.unmodifiable(<ChunkRecord>[
            for (int i = 0; i < items.length; i++)
              _chunkAt(items, i, startIndex + i),
          ]),
        );

      default:
        throw ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'the manifest page kind must be files or chunks',
        );
    }
  }

  static const Set<String> _pageKeys = <String>{
    'manifestDigest',
    'kind',
    'fileId',
    'startIndex',
    'items',
  };

  static Map<String, Object?> _objectAt(
    List<Object?> items,
    int position,
    String what,
  ) {
    final Object? entry = items[position];
    if (entry is! Map) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        '$what[$position] must be an object',
      );
    }
    return entry.cast<String, Object?>();
  }

  /// Reads one chunk entry, requiring its index to match its place in the page.
  ///
  /// §6 says a page covers a contiguous index range, so the index is not free: a page that
  /// skipped or repeated one would cover a different set of bytes than it claims.
  static ChunkRecord _chunkAt(
    List<Object?> items,
    int position,
    int expectedIndex,
  ) {
    final Map<String, Object?> map = _objectAt(items, position, 'chunks');
    rejectUnknownKeys(map, const <String>{
      'index',
      'length',
      'sha256',
    }, 'chunks');

    final int index = parseDecimalString(
      requireField(map, 'index', 'chunks'),
      'chunks.index',
    );
    if (index != expectedIndex) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a chunks page starting at ${expectedIndex - position} must carry index '
        '$expectedIndex at position $position, not $index',
      );
    }
    final int length = parseJsonInteger(
      requireField(map, 'length', 'chunks'),
      'chunks.length',
    );
    final Object? sha256 = requireField(map, 'sha256', 'chunks');
    sha256HexToBytes(sha256, 'chunks.sha256');

    return ChunkRecord(index: index, length: length, sha256: sha256! as String);
  }

  static void _assertWithinLimits(int count, int limit, String what) {
    if (count == 0) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        '$what must carry at least one item',
      );
    }
    if (count > limit) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        '$what carries $count items, over the $limit limit',
      );
    }
  }
}

/// A page of file entries.
final class ManifestFilePage extends ManifestPage {
  const ManifestFilePage({
    required super.manifestDigest,
    required super.startIndex,
    required this.items,
  });

  final List<ManifestFile> items;

  @override
  int get length => items.length;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'manifestDigest': manifestDigest,
    'kind': 'files',
    'startIndex': startIndex.toString(),
    'items': <Object?>[for (final ManifestFile file in items) file.toJson()],
  };

  @override
  String toString() =>
      'ManifestFilePage($startIndex..${endIndex - 1}, $length files)';
}

/// A page of one file's chunk records.
final class ManifestChunkPage extends ManifestPage {
  const ManifestChunkPage({
    required super.manifestDigest,
    required this.fileId,
    required super.startIndex,
    required this.items,
  });

  final String fileId;
  final List<ChunkRecord> items;

  @override
  int get length => items.length;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'manifestDigest': manifestDigest,
    'kind': 'chunks',
    'fileId': fileId,
    'startIndex': startIndex.toString(),
    'items': items.toJson(),
  };

  @override
  String toString() =>
      'ManifestChunkPage($fileId, $startIndex..${endIndex - 1}, $length chunks)';
}

/// Splits a manifest into pages that satisfy **both** of §6's bounds.
abstract final class ManifestPager {
  /// Pages of [files], in index order.
  static List<ManifestFilePage> filePages({
    required String manifestDigest,
    required List<ManifestFile> files,
  }) {
    return _paginate<ManifestFile, ManifestFilePage>(
      items: files,
      limit: ProtocolLimits.filePageLimit,
      build: (int start, List<ManifestFile> slice) => ManifestFilePage(
        manifestDigest: manifestDigest,
        startIndex: start,
        items: slice,
      ),
      what: 'a files page',
    );
  }

  /// Pages of one file's [chunks], in index order.
  static List<ManifestChunkPage> chunkPages({
    required String manifestDigest,
    required String fileId,
    required List<ChunkRecord> chunks,
  }) {
    uuidToBytes(fileId, 'fileId');
    return _paginate<ChunkRecord, ManifestChunkPage>(
      items: chunks,
      limit: ProtocolLimits.chunkPageLimit,
      build: (int start, List<ChunkRecord> slice) => ManifestChunkPage(
        manifestDigest: manifestDigest,
        fileId: fileId,
        startIndex: start,
        items: slice,
      ),
      what: 'a chunks page',
    );
  }

  /// How many bytes a page occupies on the wire.
  static int encodedSize(ManifestPage page) =>
      utf8BytesOf(jsonEncode(page.toJson()));

  /// Greedy fill by item count, then verified against the byte bound.
  ///
  /// The verification is the point: an estimate would have to model JSON escaping, the
  /// decimal-string fields and multi-byte characters, and be right every time. Encoding
  /// the candidate page and measuring it cannot be wrong about any of them.
  static List<P> _paginate<T, P extends ManifestPage>({
    required List<T> items,
    required int limit,
    required P Function(int start, List<T> slice) build,
    required String what,
  }) {
    final List<P> pages = <P>[];
    int start = 0;
    while (start < items.length) {
      int count = 1;
      while (start + count < items.length && count < limit) {
        count++;
      }

      // Shrink until the encoded page fits, so the byte bound is enforced by measurement
      // rather than by an assumption about how large an entry is.
      P page = build(start, items.sublist(start, start + count));
      while (count > 1 &&
          encodedSize(page) > ProtocolLimits.controlBodyMaxBytes) {
        count--;
        page = build(start, items.sublist(start, start + count));
      }
      if (encodedSize(page) > ProtocolLimits.controlBodyMaxBytes) {
        throw ProtocolViolation(
          ProtocolErrorCode.resourceLimit,
          '$what cannot hold a single item within the '
          '${ProtocolLimits.controlBodyMaxBytes} byte control body limit',
        );
      }

      pages.add(page);
      start += count;
    }
    return List<P>.unmodifiable(pages);
  }
}
