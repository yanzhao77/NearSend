/// Accumulating manifest pages and sealing them, `docs/protocol/v1.0-draft1.md` §6.
///
/// §6 fixes what accepting a page must do:
///
/// > 每页覆盖连续索引区间，**重传相同页返回成功，重叠区间内容不一致拒绝**；
/// > **保存时按条目索引去重，不能用重复页增加累计数量**。
/// > 缺页、重复 fileId、块数量/长度错误、总摘要不一致时 seal 失败，不能进入 WAITING_ACCEPT。
/// > **seal 后页不可修改**。
///
/// ## Why content decides, not the range
///
/// A rule phrased as "reject an overlapping range" would reject an honest retransmission
/// that happens to use different page boundaries. §6's own wording is narrower - it rejects
/// an overlapping range whose *content differs* - so [addPage] compares entries at each
/// index and accepts a retransmission that agrees.
///
/// Index-keyed storage is what makes the second sentence hold: the accumulated count is the
/// number of distinct indices, so sending a page twice cannot inflate it. A list that
/// appended pages would pass a naive retransmission test and still count the duplicates.
///
/// ## What sealing checks, and why each check is here
///
/// Every precondition is checked before the digest, so a caller learns "you are missing a
/// page" rather than "the digest does not match" - the digest would fail for all of them and
/// say nothing about which one it was. The digest check is last and is the strongest: it is
/// what makes a manifest that arrived in pieces equal to the one the sender described.
///
/// The cleanup that §6 attaches to the 30 minute window is **not** here. [isExpired]
/// answers the question; what a server does about it - releasing staging and revoking the
/// proposal - belongs to the layer that owns that state.
library;

import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/manifest_page.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';

/// What accepting a page did.
enum PageAcceptance {
  /// The page contributed at least one index that was not already stored.
  stored,

  /// Every index the page covers was already stored with the same content.
  ///
  /// §6: "重传相同页返回成功". The caller answers success, because the page is already
  /// accounted for; treating it as an error would make a lost response unrecoverable.
  alreadyStored,
}

/// Accumulates the pages of one manifest.
class ManifestStaging {
  ManifestStaging({
    required this.transferId,
    required this.manifestDigest,
    this.protocolMajor = ProtocolLimits.protocolMajor,
    this.protocolMinor = ProtocolLimits.protocolMinor,
  }) {
    uuidToBytes(transferId, 'transferId');
    sha256HexToBytes(manifestDigest, 'manifestDigest');
  }

  final String transferId;

  /// The digest every page must carry and the sealed manifest must reproduce.
  final String manifestDigest;

  final int protocolMajor;
  final int protocolMinor;

  /// File entries, keyed by their manifest index.
  final Map<int, ManifestFile> _files = <int, ManifestFile>{};

  /// Chunk records per file, keyed by chunk index.
  final Map<String, Map<int, ChunkRecord>> _chunks =
      <String, Map<int, ChunkRecord>>{};

  bool _sealed = false;
  FrozenManifest? _frozen;
  int? _firstContentAtMillis;

  /// Whether the manifest has been sealed; §6 forbids changing it afterwards.
  bool get isSealed => _sealed;

  /// How many distinct file entries have been stored.
  ///
  /// Counted from the stored indices, so a page sent twice does not raise it.
  int get stagedFileCount => _files.length;

  /// The number of retained manifest records (file entries plus chunk entries).
  ///
  /// Every field inside either record type is bounded by the protocol, so a process-wide
  /// bound on this count is also a bound on staging heap growth. The registry owns the
  /// process-wide policy; this object only reports its current contribution.
  int get stagedEntryCount =>
      _files.length +
      _chunks.values.fold<int>(
        0,
        (int total, Map<int, ChunkRecord> records) => total + records.length,
      );

  /// How many distinct chunk records have been stored for [fileId].
  int stagedChunkCount(String fileId) => _chunks[fileId]?.length ?? 0;

  /// When the first page arrived, or null while nothing has arrived.
  int? get firstContentAtMillis => _firstContentAtMillis;

  /// Whether §6's staging window has run out.
  bool isExpired({required int nowMillis}) {
    final int? first = _firstContentAtMillis;
    if (first == null || _sealed) {
      return false;
    }
    return nowMillis - first >= ProtocolLimits.stagingTimeoutSeconds * 1000;
  }

  /// Records one page.
  ///
  /// Throws when the page contradicts what is already stored, and when the manifest has
  /// already been sealed.
  PageAcceptance addPage(ManifestPage page, {int? nowMillis}) {
    if (_sealed) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidState,
        'the manifest has been sealed and its pages may no longer change',
      );
    }
    if (page.manifestDigest != manifestDigest) {
      throw const ProtocolViolation(
        ProtocolErrorCode.manifestMismatch,
        'the page carries a different manifest digest than the transfer',
      );
    }

    _firstContentAtMillis ??= nowMillis ?? _systemNow();

    switch (page) {
      case ManifestFilePage files:
        return _addFilePage(files);
      case ManifestChunkPage chunks:
        return _addChunkPage(chunks);
    }
  }

  PageAcceptance _addFilePage(ManifestFilePage page) {
    bool inserted = false;
    for (int offset = 0; offset < page.items.length; offset++) {
      final int index = page.startIndex + offset;
      final ManifestFile incoming = page.items[offset];
      final ManifestFile? existing = _files[index];
      if (existing == null) {
        _files[index] = incoming;
        inserted = true;
        continue;
      }
      if (!_sameFile(existing, incoming)) {
        throw ProtocolViolation(
          ProtocolErrorCode.manifestMismatch,
          'file index $index already holds a different entry; an overlapping range '
          'whose content differs is refused',
        );
      }
    }
    return inserted ? PageAcceptance.stored : PageAcceptance.alreadyStored;
  }

  PageAcceptance _addChunkPage(ManifestChunkPage page) {
    final Map<int, ChunkRecord> stored = _chunks[page.fileId] ??=
        <int, ChunkRecord>{};
    bool inserted = false;
    for (int offset = 0; offset < page.items.length; offset++) {
      final int index = page.startIndex + offset;
      final ChunkRecord incoming = page.items[offset];
      final ChunkRecord? existing = stored[index];
      if (existing == null) {
        stored[index] = incoming;
        inserted = true;
        continue;
      }
      if (!_sameChunk(existing, incoming)) {
        throw ProtocolViolation(
          ProtocolErrorCode.manifestMismatch,
          'chunk $index of the file already holds a different record; an overlapping '
          'range whose content differs is refused',
        );
      }
    }
    return inserted ? PageAcceptance.stored : PageAcceptance.alreadyStored;
  }

  /// Freezes the manifest, checking §6's preconditions in the order that explains most.
  ///
  /// Calling it twice returns the same manifest rather than failing: sealing is a
  /// conclusion about what has been stored, and repeating it changes nothing.
  FrozenManifest seal() {
    final FrozenManifest? already = _frozen;
    if (already != null) {
      return already;
    }

    _assertNoGaps();
    final List<ManifestFile> ordered = _orderedFiles();
    _assertUniqueFileIds(ordered);
    _assertChunkRecordsMatch(ordered);

    final FrozenManifest frozen = FrozenManifest(
      protocolMajor: protocolMajor,
      protocolMinor: protocolMinor,
      transferId: transferId,
      files: List<ManifestFile>.unmodifiable(ordered),
    );
    // §6: "总摘要不一致时 seal 失败". This is the strongest check and the last one, because
    // it fails for every earlier problem too and would say nothing about which.
    frozen.verifyDigest(manifestDigest);

    _frozen = frozen;
    _sealed = true;
    return frozen;
  }

  /// §6: "缺页……时 seal 失败".
  void _assertNoGaps() {
    if (_files.isEmpty) {
      throw const ProtocolViolation(
        ProtocolErrorCode.manifestMismatch,
        'no file page has been received, so the manifest cannot be sealed',
      );
    }
    final int highest = _files.keys.reduce((int a, int b) => a > b ? a : b);
    for (int index = 0; index <= highest; index++) {
      if (!_files.containsKey(index)) {
        throw ProtocolViolation(
          ProtocolErrorCode.manifestMismatch,
          'file index $index is missing, so the manifest cannot be sealed',
        );
      }
    }
  }

  /// Rebuilds the list in index order.
  ///
  /// §5 fixes the array order as the logical order the user confirmed, and a page's start
  /// index is what carries that order - so storing by index and reading back in ascending
  /// order reproduces the original array even when pages arrive out of order.
  List<ManifestFile> _orderedFiles() {
    final List<int> indices = _files.keys.toList()..sort();
    return <ManifestFile>[for (final int index in indices) _files[index]!];
  }

  /// §6: "重复 fileId……时 seal 失败".
  void _assertUniqueFileIds(List<ManifestFile> files) {
    final Set<String> seen = <String>{};
    for (final ManifestFile file in files) {
      if (!seen.add(file.fileId)) {
        throw ProtocolViolation(
          ProtocolErrorCode.manifestMismatch,
          'file ${file.fileId} appears more than once in the manifest',
        );
      }
    }
  }

  /// §6: "块数量/长度错误……时 seal 失败".
  void _assertChunkRecordsMatch(List<ManifestFile> files) {
    final Set<String> fileIds = <String>{
      for (final ManifestFile file in files) file.fileId,
    };
    for (final String fileId in _chunks.keys) {
      if (!fileIds.contains(fileId)) {
        throw ProtocolViolation(
          ProtocolErrorCode.manifestMismatch,
          'chunk pages were received for $fileId, which no file page declares',
        );
      }
    }

    for (final ManifestFile file in files) {
      final Map<int, ChunkRecord> stored =
          _chunks[file.fileId] ?? const <int, ChunkRecord>{};
      for (int index = 0; index < file.chunkCount; index++) {
        final ChunkRecord? record = stored[index];
        if (record == null) {
          throw ProtocolViolation(
            ProtocolErrorCode.manifestMismatch,
            'chunk $index of ${file.fileId} is missing, so the manifest cannot be '
            'sealed',
          );
        }
        // §5.3 fixes the length from the file size, so a peer cannot declare a short
        // chunk to skip bytes.
        final int expected = chunkLengthForIndex(
          file.sizeBytes,
          file.chunkSizeBytes,
          index,
        );
        if (record.length != expected) {
          throw ProtocolViolation(
            ProtocolErrorCode.manifestMismatch,
            'chunk $index of ${file.fileId} declares ${record.length} bytes but the '
            'file size requires $expected',
          );
        }
      }
      if (stored.length != file.chunkCount) {
        throw ProtocolViolation(
          ProtocolErrorCode.manifestMismatch,
          '${file.fileId} has ${stored.length} chunk records but declares '
          '${file.chunkCount}',
        );
      }
    }
  }

  /// The sealed manifest, or null while the manifest is still being assembled.
  FrozenManifest? get frozenManifest => _frozen;

  static bool _sameFile(ManifestFile a, ManifestFile b) =>
      a.fileId == b.fileId &&
      a.relativePath == b.relativePath &&
      a.sizeBytes == b.sizeBytes &&
      a.chunkSizeBytes == b.chunkSizeBytes &&
      a.chunkCount == b.chunkCount &&
      a.fileSha256 == b.fileSha256 &&
      a.chunkManifestDigest == b.chunkManifestDigest;

  static bool _sameChunk(ChunkRecord a, ChunkRecord b) =>
      a.index == b.index && a.length == b.length && a.sha256 == b.sha256;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;
}
