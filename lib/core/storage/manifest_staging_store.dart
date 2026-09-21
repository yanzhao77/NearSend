/// Manifest staging, persisted, `docs/decisions/ADR-0004-staging持久化与恢复权威.md`.
///
/// ## What ADR-0004 requires and why this file exists
///
/// The first implementation kept a proposal's pages in a process-local
/// [ManifestStaging], and the registry's own comment said what that cost: **a sealed manifest
/// from before a restart was gone**. ADR-0004 settled that production staging must enter
/// SQLite, and the consequences are concrete:
///
/// * an **unsealed** proposal can be continued after a restart, because its pages are rows;
/// * a **sealed** manifest is still readable after a restart, so `decision`, chunk
///   verification and `resume` can be served from it;
/// * §6's thirty-minute window runs from a persisted `first_content_at`, so a restart cannot
///   hand a stale proposal a fresh thirty minutes;
/// * §6's lifecycle cleanup has somewhere to write what it did, which is
///   `released_at`.
///
/// ## Why the index is part of the primary key
///
/// §6 forbids a re-sent page from inflating the accumulated count. Storing file entries by
/// their manifest index (`PRIMARY KEY (transfer_id, file_index)`) and chunk entries by their
/// index inside the file makes that a property of the schema: a page that arrives twice writes
/// the same primary keys, so there is no second row to count. An append-only table would pass
/// a naive retransmission test and still count the duplicates, which is the failure
/// `t03-01-05` recorded for the in-memory version and this schema reproduces structurally.
///
/// The same keying makes §6's other page rule fall out: "重叠区间内容不一致拒绝" is a
/// primary-key conflict whose stored content differs, which is checked per row rather than by
/// comparing ranges.
///
/// ## Why sealing reuses [ManifestStaging]
///
/// The seal's preconditions - no gaps, unique file ids, chunk records matching the declared
/// sizes, and the total digest last - are already implemented and heavily tested in
/// `manifest_staging.dart`. Re-implementing them over SQL rows would be a second definition of
/// §6's seal order, and the two would drift. So [seal] **materialises** the stored rows into a
/// [ManifestStaging] and calls its `seal()`. That object is transient by construction: it
/// exists for the duration of the transaction and is never retained, which is what keeps
/// "do not depend on a long-lived in-memory sealed manifest" true.
///
/// The frozen manifest is then **written back** as JSON ([StorageSchema.sealedManifestColumn])
/// so later reads - decision, chunk verification, resume, a second seal - do not need the
/// accumulator at all.
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/manifest_page.dart';
import 'package:nearsend/core/protocol/manifest_staging.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_failure.dart';
import 'package:nearsend/core/storage/storage_schema.dart';

/// Why a staging proposal was released from active use.
enum StagingReleaseReason {
  /// §6: the manifest was frozen and the proposal became a task.
  sealed,

  /// The user or the peer cancelled the transfer.
  cancelled,

  /// The task reached a terminal failure.
  failed,

  /// §6's thirty-minute window ran out on an unfinished proposal.
  expired,
}

/// A staging proposal's stored header, without its pages.
class StagingRecord {
  const StagingRecord({
    required this.transferId,
    required this.manifestDigest,
    required this.protocolMajor,
    required this.protocolMinor,
    required this.createdAtMillis,
    this.firstContentAtMillis,
    this.sealedAtMillis,
    this.releasedAtMillis,
  });

  final String transferId;

  /// The digest every page must carry and the sealed manifest must reproduce (§6).
  final String manifestDigest;

  final int protocolMajor;
  final int protocolMinor;
  final int createdAtMillis;

  /// When the first page arrived, which is where §6's window starts.
  final int? firstContentAtMillis;

  /// When the manifest was frozen, or null while it is still a proposal.
  final int? sealedAtMillis;

  /// When the proposal left active use, or null while it is still current.
  final int? releasedAtMillis;

  bool get isSealed => sealedAtMillis != null;
  bool get isReleased => releasedAtMillis != null;

  @override
  String toString() =>
      'StagingRecord($transferId, digest=$manifestDigest, '
      'sealed=${sealedAtMillis != null}, released=${releasedAtMillis != null})';
}

/// Reads and writes manifest staging for one database.
class ManifestStagingStore {
  ManifestStagingStore(this.database);

  final NearSendDatabase database;

  /// Starts - or finds - the staging proposal for [transferId].
  ///
  /// The header is built from the transfer's own declaration rather than from the caller, so
  /// the protocol version and digest a proposal is checked against cannot be supplied by
  /// whoever happens to be holding the registry.
  ///
  /// Throws `NOT_FOUND` when no such task exists and `INVALID_STATE` when the task has no
  /// declared digest, which means it was not created by this build.
  StagingRecord ensureStaging(String transferId, {int? nowMillis}) {
    return database.transaction(() {
      final StagingRecord? existing = readRecord(transferId);
      if (existing != null) {
        return existing;
      }

      final ResultSet tasks = database.db.select(
        'SELECT manifest_digest, protocol_major, protocol_minor, state FROM tasks '
        'WHERE task_id = ?;',
        <Object?>[transferId],
      );
      if (tasks.isEmpty) {
        throw const ProtocolViolation(
          ProtocolErrorCode.notFound,
          'no transfer with that id is registered',
        );
      }
      final Row row = tasks.first;
      final String? digest = row['manifest_digest'] as String?;
      if (digest == null) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidState,
          'the transfer has no declared manifest digest, so no page can be checked '
          'against it',
        );
      }

      final int now = nowMillis ?? _systemNow();
      database.db.execute(
        'INSERT INTO ${StorageSchema.manifestStagingTable} '
        '(transfer_id, manifest_digest, protocol_major, protocol_minor, '
        '${StorageSchema.firstContentAtColumn}, sealed_at, '
        '${StorageSchema.sealedManifestColumn}, seal_result_json, released_at, '
        'created_at) VALUES (?, ?, ?, ?, NULL, NULL, NULL, NULL, NULL, ?) '
        'ON CONFLICT(transfer_id) DO NOTHING;',
        <Object?>[
          transferId,
          digest,
          row['protocol_major'] as int,
          row['protocol_minor'] as int,
          now,
        ],
      );
      return readRecord(transferId)!;
    });
  }

  /// The stored header for [transferId], or null when nothing is staged.
  StagingRecord? readRecord(String transferId) {
    final ResultSet rows = database.db.select(
      'SELECT manifest_digest, protocol_major, protocol_minor, '
      '${StorageSchema.firstContentAtColumn}, sealed_at, released_at, created_at '
      'FROM ${StorageSchema.manifestStagingTable} WHERE transfer_id = ?;',
      <Object?>[transferId],
    );
    if (rows.isEmpty) {
      return null;
    }
    final Row row = rows.first;
    return StagingRecord(
      transferId: transferId,
      manifestDigest: row['manifest_digest'] as String,
      protocolMajor: row['protocol_major'] as int,
      protocolMinor: row['protocol_minor'] as int,
      createdAtMillis: row['created_at'] as int,
      firstContentAtMillis: row[StorageSchema.firstContentAtColumn] as int?,
      sealedAtMillis: row['sealed_at'] as int?,
      releasedAtMillis: row['released_at'] as int?,
    );
  }

  /// Stores one page, refusing content that contradicts what is already stored.
  ///
  /// Both outcomes of §6's retransmission rule are returned rather than one being an error,
  /// because the client that lost a response cannot tell them apart; the caller answers
  /// `200 {stored:true}` either way.
  ///
  /// Refuses when the manifest has been frozen (§6: "seal 后页不可修改") and when the page
  /// carries a different digest than the transfer.
  PageAcceptance addPage(
    String transferId,
    ManifestPage page, {
    int? nowMillis,
  }) {
    final int now = nowMillis ?? _systemNow();
    return database.transaction(() {
      final StagingRecord record = ensureStaging(transferId, nowMillis: now);
      if (record.isSealed) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidState,
          'the manifest has been sealed and its pages may no longer change',
        );
      }
      if (record.isReleased) {
        // A released-but-unsealed proposal is what §6's window leaves behind. Accepting a page
        // here would reopen a proposal the protocol says is revoked, and the durable marker
        // exists precisely so this cannot happen by accident after a restart.
        throw const ProtocolViolation(
          ProtocolErrorCode.taskExpired,
          'the incomplete staging proposal has expired',
        );
      }
      if (page.manifestDigest != record.manifestDigest) {
        throw const ProtocolViolation(
          ProtocolErrorCode.manifestMismatch,
          'the page carries a different manifest digest than the transfer',
        );
      }

      if (record.firstContentAtMillis == null) {
        // §6's window starts at the first *content*, not at the offer, so this is written
        // exactly once and survives a restart.
        database.db.execute(
          'UPDATE ${StorageSchema.manifestStagingTable} SET '
          '${StorageSchema.firstContentAtColumn} = ? WHERE transfer_id = ?;',
          <Object?>[now, transferId],
        );
      }

      switch (page) {
        case ManifestFilePage files:
          return _addFilePage(transferId, files);
        case ManifestChunkPage chunks:
          return _addChunkPage(transferId, chunks);
      }
    });
  }

  PageAcceptance _addFilePage(String transferId, ManifestFilePage page) {
    bool inserted = false;
    for (int offset = 0; offset < page.items.length; offset++) {
      final int index = page.startIndex + offset;
      final ManifestFile incoming = page.items[offset];
      database.db.execute(
        'INSERT INTO ${StorageSchema.manifestFilesTable} (transfer_id, file_index, '
        'file_id, relative_path, size_bytes, chunk_size_bytes, chunk_count, '
        'file_sha256, chunk_manifest_digest) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(transfer_id, file_index) DO NOTHING;',
        <Object?>[
          transferId,
          index,
          incoming.fileId,
          incoming.relativePath,
          incoming.sizeBytes,
          incoming.chunkSizeBytes,
          incoming.chunkCount,
          incoming.fileSha256,
          incoming.chunkManifestDigest,
        ],
      );
      if (database.db.updatedRows > 0) {
        inserted = true;
        continue;
      }
      if (!_storedFileMatches(transferId, index, incoming)) {
        throw ProtocolViolation(
          ProtocolErrorCode.manifestMismatch,
          'file index $index already holds a different entry; an overlapping range '
          'whose content differs is refused',
        );
      }
    }
    return inserted ? PageAcceptance.stored : PageAcceptance.alreadyStored;
  }

  PageAcceptance _addChunkPage(String transferId, ManifestChunkPage page) {
    bool inserted = false;
    for (int offset = 0; offset < page.items.length; offset++) {
      final int index = page.startIndex + offset;
      final ChunkRecord incoming = page.items[offset];
      database.db.execute(
        'INSERT INTO ${StorageSchema.manifestChunksTable} (transfer_id, file_id, '
        'chunk_index, length_bytes, sha256) VALUES (?, ?, ?, ?, ?) '
        'ON CONFLICT(transfer_id, file_id, chunk_index) DO NOTHING;',
        <Object?>[
          transferId,
          page.fileId,
          index,
          incoming.length,
          incoming.sha256,
        ],
      );
      if (database.db.updatedRows > 0) {
        inserted = true;
        continue;
      }
      if (!_storedChunkMatches(transferId, page.fileId, index, incoming)) {
        throw ProtocolViolation(
          ProtocolErrorCode.manifestMismatch,
          'chunk $index of the file already holds a different record; an overlapping '
          'range whose content differs is refused',
        );
      }
    }
    return inserted ? PageAcceptance.stored : PageAcceptance.alreadyStored;
  }

  bool _storedFileMatches(String transferId, int index, ManifestFile incoming) {
    final ResultSet rows = database.db.select(
      'SELECT file_id, relative_path, size_bytes, chunk_size_bytes, chunk_count, '
      'file_sha256, chunk_manifest_digest FROM '
      '${StorageSchema.manifestFilesTable} WHERE transfer_id = ? AND file_index = ?;',
      <Object?>[transferId, index],
    );
    if (rows.isEmpty) {
      return false;
    }
    final Row row = rows.first;
    return row['file_id'] == incoming.fileId &&
        row['relative_path'] == incoming.relativePath &&
        row['size_bytes'] == incoming.sizeBytes &&
        row['chunk_size_bytes'] == incoming.chunkSizeBytes &&
        row['chunk_count'] == incoming.chunkCount &&
        row['file_sha256'] == incoming.fileSha256 &&
        row['chunk_manifest_digest'] == incoming.chunkManifestDigest;
  }

  bool _storedChunkMatches(
    String transferId,
    String fileId,
    int index,
    ChunkRecord incoming,
  ) {
    final ResultSet rows = database.db.select(
      'SELECT length_bytes, sha256 FROM ${StorageSchema.manifestChunksTable} '
      'WHERE transfer_id = ? AND file_id = ? AND chunk_index = ?;',
      <Object?>[transferId, fileId, index],
    );
    if (rows.isEmpty) {
      return false;
    }
    final Row row = rows.first;
    return row['length_bytes'] == incoming.length &&
        row['sha256'] == incoming.sha256;
  }

  /// Freezes the stored manifest and records the seal.
  ///
  /// Runs entirely inside one transaction that the caller may already have opened, so §6's
  /// "seal、任务状态迁移和幂等结果保持事务一致" is achievable: the frozen manifest, the seal
  /// timestamp and the task's move to `WAITING_ACCEPT` either all commit or none do.
  ///
  /// Calling it twice for the same digest returns the stored frozen manifest rather than
  /// failing, which is what makes the seal's partially-in-memory history irrelevant here and
  /// keeps a retry after a failed transaction able to finish.
  FrozenManifest seal(String transferId, {int? nowMillis}) {
    final int now = nowMillis ?? _systemNow();
    return database.transaction(() {
      final StagingRecord record = ensureStaging(transferId, nowMillis: now);

      final FrozenManifest? already = readFrozenManifest(transferId);
      if (already != null) {
        return already;
      }

      final ManifestStaging staging = materialise(record);
      // §6's order lives in `seal`: gaps, duplicate file ids, chunk records, and the total
      // digest last. A failure throws MANIFEST_MISMATCH and this transaction rolls back, so
      // the task stays in STAGING and the client may add more pages and retry -
      // §6: "不能进入 WAITING_ACCEPT".
      final FrozenManifest frozen = staging.seal();

      database.db.execute(
        'UPDATE ${StorageSchema.manifestStagingTable} SET sealed_at = ?, '
        '${StorageSchema.sealedManifestColumn} = ?, seal_result_json = ? '
        'WHERE transfer_id = ?;',
        <Object?>[
          now,
          jsonEncode(frozen.toJson()),
          jsonEncode(<String, Object?>{
            'fileCount': frozen.fileCount,
            'totalBytes': frozen.totalBytes.toString(),
            'manifestDigest': frozen.manifestDigest,
          }),
          transferId,
        ],
      );
      return frozen;
    });
  }

  /// The frozen manifest for [transferId], or null while it is still a proposal.
  ///
  /// Reads the stored JSON rather than an accumulator, so this is the same answer before and
  /// after a restart - which is the property ADR-0004 asked for.
  FrozenManifest? readFrozenManifest(String transferId) {
    final ResultSet rows = database.db.select(
      'SELECT ${StorageSchema.sealedManifestColumn} FROM '
      '${StorageSchema.manifestStagingTable} WHERE transfer_id = ? '
      'AND sealed_at IS NOT NULL;',
      <Object?>[transferId],
    );
    if (rows.isEmpty) {
      return null;
    }
    final Object? stored = rows.first[StorageSchema.sealedManifestColumn];
    if (stored is! String) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'transfer $transferId is marked sealed but its frozen manifest was not stored',
      );
    }
    final Object? decoded = jsonDecode(stored);
    if (decoded is! Map) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'the stored frozen manifest for $transferId is not an object',
      );
    }
    // Parsed with the protocol's own reader, so a body this build cannot read fails here
    // rather than becoming an unvalidated manifest in a decision response.
    return FrozenManifest.fromJson(decoded.cast<String, Object?>());
  }

  /// The stored file entries of a proposal, ascending by manifest index.
  List<ManifestFile> readFilePage(
    String transferId, {
    required int startIndex,
    required int limit,
  }) {
    final ResultSet rows = database.db.select(
      'SELECT file_id, relative_path, size_bytes, chunk_size_bytes, chunk_count, '
      'file_sha256, chunk_manifest_digest FROM '
      '${StorageSchema.manifestFilesTable} WHERE transfer_id = ? AND file_index >= ? '
      'ORDER BY file_index LIMIT ?;',
      <Object?>[transferId, startIndex, limit],
    );
    return <ManifestFile>[
      for (final Row row in rows)
        ManifestFile(
          fileId: row['file_id'] as String,
          relativePath: row['relative_path'] as String,
          sizeBytes: row['size_bytes'] as int,
          chunkSizeBytes: row['chunk_size_bytes'] as int,
          chunkCount: row['chunk_count'] as int,
          fileSha256: row['file_sha256'] as String,
          chunkManifestDigest: row['chunk_manifest_digest'] as String,
        ),
    ];
  }

  /// The stored chunk records of one file, ascending by chunk index.
  List<ChunkRecord> readChunkPage(
    String transferId, {
    required String fileId,
    required int startIndex,
    required int limit,
  }) {
    final ResultSet rows = database.db.select(
      'SELECT chunk_index, length_bytes, sha256 FROM '
      '${StorageSchema.manifestChunksTable} WHERE transfer_id = ? AND file_id = ? '
      'AND chunk_index >= ? ORDER BY chunk_index LIMIT ?;',
      <Object?>[transferId, fileId, startIndex, limit],
    );
    return <ChunkRecord>[
      for (final Row row in rows)
        ChunkRecord(
          index: row['chunk_index'] as int,
          length: row['length_bytes'] as int,
          sha256: row['sha256'] as String,
        ),
    ];
  }

  /// How many file entries a proposal has stored.
  int stagedFileCount(String transferId) => _count(
    'SELECT COUNT(*) AS c FROM ${StorageSchema.manifestFilesTable} '
    'WHERE transfer_id = ?;',
    transferId,
  );

  /// How many chunk records a proposal has stored.
  int stagedChunkCount(String transferId) => _count(
    'SELECT COUNT(*) AS c FROM ${StorageSchema.manifestChunksTable} '
    'WHERE transfer_id = ?;',
    transferId,
  );

  /// Every staging proposal that has not been released, sealed or not.
  List<String> openTransferIds() {
    final ResultSet rows = database.db.select(
      'SELECT transfer_id FROM ${StorageSchema.manifestStagingTable} '
      'WHERE released_at IS NULL ORDER BY created_at;',
    );
    return <String>[for (final Row row in rows) row['transfer_id'] as String];
  }

  /// How many proposals are open, optionally filtered by whether they are sealed.
  ///
  /// A proposal is *open* when it has not been released. The distinction matters because a
  /// sealed manifest that is still open must remain readable for decision, chunk verification
  /// and resume, while a released one is no longer this process's business.
  int countOpen({required bool? sealed}) {
    final String filter = switch (sealed) {
      null => '',
      true => ' AND sealed_at IS NOT NULL',
      false => ' AND sealed_at IS NULL',
    };
    final ResultSet rows = database.db.select(
      'SELECT COUNT(*) AS c FROM ${StorageSchema.manifestStagingTable} '
      'WHERE released_at IS NULL$filter;',
    );
    return rows.first['c'] as int;
  }

  /// Total retained manifest records across every open proposal.
  ///
  /// This matters because a peer can create proposals; without a bound one connection could
  /// pin storage with pages nobody finished. It is read from SQLite rather than tracked in a
  /// counter that a failed transaction could desynchronise from the rows.
  int retainedRecordCount() {
    final ResultSet rows = database.db.select(
      'SELECT (SELECT COUNT(*) FROM ${StorageSchema.manifestFilesTable}) + '
      '(SELECT COUNT(*) FROM ${StorageSchema.manifestChunksTable}) AS c;',
    );
    return rows.first['c'] as int;
  }

  /// Whether §6's thirty-minute window has run out on [transferId].
  ///
  /// False for a sealed manifest: §6 is emphatic that the window "不影响已经冻结的任务", and a
  /// window that also discarded a frozen manifest would revoke a proposal the user had
  /// already completed.
  bool isExpired(String transferId, {required int nowMillis}) {
    final StagingRecord? record = readRecord(transferId);
    if (record == null || record.isSealed) {
      return false;
    }
    final int? first = record.firstContentAtMillis;
    if (first == null) {
      return false;
    }
    return nowMillis - first >= ProtocolLimits.stagingTimeoutSeconds * 1000;
  }

  /// Marks a proposal as no longer in active use, recording when.
  ///
  /// The rows are kept: a sealed manifest must remain readable for decision, chunk
  /// verification and resume, and a cancelled proposal's files remain part of the task's
  /// history. [discard] is the operation that removes them.
  void release(
    String transferId,
    StagingReleaseReason reason, {
    int? nowMillis,
  }) {
    final int now = nowMillis ?? _systemNow();
    database.transaction(() {
      database.db.execute(
        'UPDATE ${StorageSchema.manifestStagingTable} SET released_at = ? '
        'WHERE transfer_id = ? AND released_at IS NULL;',
        <Object?>[now, transferId],
      );
    });
  }

  /// Removes a proposal and every page of it.
  ///
  /// Only for a proposal that was never sealed: discarding a sealed manifest would make the
  /// task's own files unverifiable, so this refuses rather than doing it.
  void discard(String transferId) {
    database.transaction(() {
      final StagingRecord? record = readRecord(transferId);
      if (record == null) {
        return;
      }
      if (record.isSealed) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidState,
          'a sealed manifest may not be discarded; its files are the task of record',
        );
      }
      database.db.execute(
        'DELETE FROM ${StorageSchema.manifestChunksTable} WHERE transfer_id = ?;',
        <Object?>[transferId],
      );
      database.db.execute(
        'DELETE FROM ${StorageSchema.manifestFilesTable} WHERE transfer_id = ?;',
        <Object?>[transferId],
      );
      database.db.execute(
        'DELETE FROM ${StorageSchema.manifestStagingTable} WHERE transfer_id = ?;',
        <Object?>[transferId],
      );
    });
  }

  /// Rebuilds a transient accumulator from the stored rows.
  ///
  /// Transient by construction: the result is used to run §6's seal checks and is never
  /// retained. That is what keeps this build from depending on a long-lived in-memory sealed
  /// manifest, which ADR-0004 forbids.
  ManifestStaging materialise(StagingRecord record) {
    final ManifestStaging staging = ManifestStaging(
      transferId: record.transferId,
      manifestDigest: record.manifestDigest,
      protocolMajor: record.protocolMajor,
      protocolMinor: record.protocolMinor,
    );

    final List<ManifestFile> files = readFilePage(
      record.transferId,
      startIndex: 0,
      limit: ProtocolLimits.maxFilesPerTransfer,
    );
    if (files.isNotEmpty) {
      // The constructors do not apply §6's page caps; those belong to a page arriving on the
      // wire, not to a rebuild from storage.
      staging.addPage(
        ManifestFilePage(
          manifestDigest: record.manifestDigest,
          startIndex: 0,
          items: List<ManifestFile>.unmodifiable(files),
        ),
        nowMillis: record.firstContentAtMillis ?? record.createdAtMillis,
      );
    }

    for (final ManifestFile file in files) {
      final List<ChunkRecord> chunks = readChunkPage(
        record.transferId,
        fileId: file.fileId,
        startIndex: 0,
        limit: ProtocolLimits.maxChunksPerTransfer,
      );
      if (chunks.isEmpty) {
        continue;
      }
      staging.addPage(
        ManifestChunkPage(
          manifestDigest: record.manifestDigest,
          fileId: file.fileId,
          startIndex: 0,
          items: List<ChunkRecord>.unmodifiable(chunks),
        ),
        nowMillis: record.firstContentAtMillis ?? record.createdAtMillis,
      );
    }

    return staging;
  }

  int _count(String sql, String transferId) {
    final ResultSet rows = database.db.select(sql, <Object?>[transferId]);
    return rows.first['c'] as int;
  }

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;
}

/// The digest a staged page's index arithmetic relies on: a canonical SHA-256 hex string.
///
/// Kept next to the store so a caller that has a digest in hand can check it before opening a
/// transaction, instead of discovering the problem after rows have been written.
void assertCanonicalDigest(String value, String field) =>
    sha256HexToBytes(value, field);
