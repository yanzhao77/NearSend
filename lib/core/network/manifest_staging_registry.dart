/// Where a transfer's staged manifest pages live while it is being proposed.
///
/// §6's sequence is "`POST /transfers` 创建 staging 任务；分批 `PUT` 文件页和块页；`POST /seal`",
/// so the pages of one transfer accumulate across many requests and have to be reachable by
/// the next one.
///
/// ## What changed, and why the old comment had to go
///
/// The first implementation held the accumulator ([ManifestStaging]) in a `Map` on this
/// object, and its own comment said the cost plainly: **a sealed manifest from before a
/// restart was gone**, so the build "must not claim that a transfer survives a server
/// restart". ADR-0004 requires production staging in SQLite, and that is what this class now
/// mediates: the pages are rows ([ManifestStagingStore]), and this object holds no manifest at
/// all - only the process-wide policy that a peer's proposals must not be able to pin the
/// process.
///
/// So the two things ADR-0004 asked for are true now, and each has a test:
///
/// * an **unsealed** proposal continues after a restart - its pages are rows, so the next
///   request accumulates onto them;
/// * a **sealed** manifest is readable after a restart, which is what `decision`, chunk
///   verification and `resume` need. [frozenManifest] reads the stored JSON rather than an
///   accumulator.
///
/// ## §6's thirty-minute window, and why expiry marks rather than deletes
///
/// §6: "首次收到内容后 30 分钟 staging 未完成则清理并撤销该提议；**不影响已经冻结的任务**".
/// The window starts at the first content, which is now a persisted timestamp, so a restart
/// cannot hand a stale proposal a fresh thirty minutes.
///
/// An expired proposal is **released** (`released_at`), not deleted. Deleting it would let the
/// very next request rebuild it from the task row and reopen a proposal §6 says is revoked -
/// the in-memory version avoided that with a separate `_expired` set, and a durable marker is
/// the same idea without the memory. It also keeps the lifecycle timeline the task asks to be
/// able to read back.
///
/// ## Why the two limits survive
///
/// [maxConcurrentTransfers] and [maxRetainedEntries] bound what a peer can make this process
/// hold. Under SQLite the second bounds rows rather than heap, which is a different resource -
/// so it is kept, and the heap itself is bounded by never holding a whole manifest outside a
/// seal transaction.
library;

import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/manifest_page.dart';
import 'package:nearsend/core/protocol/manifest_staging.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/manifest_staging_store.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

export 'package:nearsend/core/storage/manifest_staging_store.dart'
    show StagingReleaseReason, StagingRecord;

/// The staging state of the transfers this process is proposing.
class ManifestStagingRegistry {
  ManifestStagingRegistry({
    required this.transfers,
    ManifestStagingStore? store,
    int Function()? now,
    this.maxConcurrentTransfers = 8,
    this.maxRetainedEntries = 262144,
  }) : assert(maxConcurrentTransfers > 0),
       assert(maxRetainedEntries > 0),
       store = store ?? ManifestStagingStore(transfers.database),
       now = now ?? _systemNow;

  /// Reads the declaration a staging session must be built from.
  final TransferRepository transfers;

  /// Where the pages actually live. Owning it here rather than letting each caller make one
  /// keeps a single view of what is stored, the same argument as the write fence.
  final ManifestStagingStore store;

  /// Clock injection, so a test does not have to wait thirty minutes.
  final int Function() now;

  /// Maximum number of proposals held open for peers at once.
  final int maxConcurrentTransfers;

  /// Maximum retained file + chunk records across all proposals.
  ///
  /// Every field inside either record type is bounded by the protocol, so this is also a
  /// bound on what a peer can make the database grow by with pages nobody finished.
  final int maxRetainedEntries;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  /// Proposals held open: not released, whether sealed or not.
  int get stagedTransferCount => _openCount(sealed: null);

  /// Proposals whose manifest has been frozen and that have not been released.
  int get sealedTransferCount => _openCount(sealed: true);

  /// Retained manifest records across every proposal, read from the database rather than
  /// tracked in a counter a failed transaction could desynchronise from the rows.
  int get retainedEntryCount => store.retainedRecordCount();

  /// Transfers with an open proposal, ascending by creation time.
  List<String> openTransferIds() => store.openTransferIds();

  /// The staging for [transferId], as a transient view of what is stored.
  ///
  /// The returned [ManifestStaging] is **built from the rows and then dropped**: it is the
  /// shape callers already read (`stagedFileCount`, `isSealed`, `firstContentAtMillis`) without
  /// being a place where a manifest lives. A caller that wants to add a page goes through
  /// [addPage] so the page reaches SQLite; mutating the returned object would change nothing
  /// durable, and that is deliberate.
  ///
  /// Throws `NOT_FOUND` when no such transfer exists - §7 answers an unknown or unauthorised
  /// resource the same way, and a client cannot use this to learn which transfer ids exist.
  /// Throws `TASK_EXPIRED` when §6's window has run out on a proposal that is still
  /// incomplete.
  ManifestStaging stagingFor(String transferId) =>
      _viewOf(_recordFor(transferId));

  /// Adds a page, writing it to SQLite and enforcing the process-wide record budget.
  PageAcceptance addPage(
    String transferId,
    ManifestPage page, {
    int? nowMillis,
  }) {
    // Resolved first so §6's window, §7's not-found rule and the concurrency limit all apply
    // to a page write and not only to a read: a client whose proposal expired must be told so
    // rather than having the page quietly accepted.
    _recordFor(transferId);

    // One transaction so a page that pushes the budget over the line is never left behind:
    // the discard has to commit, and a `throw` inside the transaction would roll it back.
    late PageAcceptance acceptance;
    final bool overBudget = transfers.database.transaction(() {
      acceptance = store.addPage(
        transferId,
        page,
        nowMillis: nowMillis ?? now(),
      );
      if (store.retainedRecordCount() > maxRetainedEntries) {
        // This proposal failed its resource contract. Keeping its rows would allow a peer to
        // pin the database at the limit; the client may start it again in smaller pages.
        store.discard(transferId);
        return true;
      }
      return false;
    });
    if (overBudget) {
      throw const ProtocolViolation(
        ProtocolErrorCode.resourceLimit,
        'the manifest staging record budget has been reached',
      );
    }
    return acceptance;
  }

  /// Freezes a proposal's manifest and records the seal.
  ///
  /// The work happens in the caller's transaction when there is one - the seal endpoint opens
  /// §9's idempotency transaction around it - so the frozen manifest, the seal timestamp and
  /// the task's move to `WAITING_ACCEPT` commit together or not at all.
  FrozenManifest seal(String transferId, {int? nowMillis}) {
    _recordFor(transferId);
    return store.seal(transferId, nowMillis: nowMillis ?? now());
  }

  /// The digest the transfer declared, which §6's seal has to agree with.
  ///
  /// Read without materialising the manifest, so the endpoint's digest check does not cost a
  /// full rebuild of what may be a ten-thousand-file proposal.
  String declaredDigest(String transferId) =>
      _recordFor(transferId).manifestDigest;

  /// The frozen manifest of [transferId], or null while it is still a proposal.
  ///
  /// Read from storage, so this is the same answer before and after a restart.
  FrozenManifest? frozenManifest(String transferId) {
    if (store.readRecord(transferId) == null) {
      return null;
    }
    return store.readFrozenManifest(transferId);
  }

  /// Whether §6's window has run out on [transferId].
  bool isExpired(String transferId, {required int nowMillis}) =>
      store.isExpired(transferId, nowMillis: nowMillis);

  /// Releases a proposal after a terminal lifecycle event.
  ///
  /// A retryable seal validation error is deliberately not terminal: its pages stay available
  /// so the sender can supply what is missing. Sealed, cancelled and terminally failed tasks
  /// must use this so the open-proposal count cannot grow for the lifetime of the process.
  void release(String transferId, StagingReleaseReason reason) {
    store.release(transferId, reason, nowMillis: now());
  }

  /// Forgets a proposal's pages. Only for one that was never sealed.
  void discard(String transferId) => store.discard(transferId);

  /// Releases every unsealed proposal whose window has run out.
  ///
  /// Returns the transfers it released, so a caller can report what it cleaned up.
  List<String> sweepExpired() => _sweepExpired();

  List<String> _sweepExpired() {
    final int moment = now();
    final List<String> released = <String>[];
    for (final String transferId in store.openTransferIds()) {
      if (store.isExpired(transferId, nowMillis: moment)) {
        store.release(
          transferId,
          StagingReleaseReason.expired,
          nowMillis: moment,
        );
        released.add(transferId);
      }
    }
    return released;
  }

  /// Resolves the stored record for [transferId], creating it when the transfer is new.
  ///
  /// This is where §7's not-found rule, §6's window, the task-state rule and the concurrency
  /// limit all live, so every entry point - a page write, a seal and a read - is subject to the
  /// same four checks instead of each remembering the ones it happened to need.
  StagingRecord _recordFor(String transferId) {
    _sweepExpired();

    final StagingRecord? existing = store.readRecord(transferId);
    if (existing != null) {
      if (!existing.isSealed && existing.isReleased) {
        throw const ProtocolViolation(
          ProtocolErrorCode.taskExpired,
          'nothing was received for this transfer within §6s thirty-minute window, so the '
          'proposal has been discarded',
        );
      }
      return existing;
    }

    final TransferDeclaration? declaration = transfers.readDeclaration(
      transferId,
    );
    if (declaration == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.notFound,
        'no transfer with that id is registered',
      );
    }
    if (transfers.taskState(transferId) != TransferState.staging) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidState,
        'manifest staging is only available while the task is in STAGING',
      );
    }
    if (declaration.manifestDigest == null) {
      // §7's creation carries the digest, so a transfer without one was not created by this
      // build. Refusing is the honest answer: there is nothing to verify pages against.
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidState,
        'the transfer has no declared manifest digest, so no page can be checked against it',
      );
    }
    if (_openCount(sealed: null) >= maxConcurrentTransfers) {
      throw const ProtocolViolation(
        ProtocolErrorCode.resourceLimit,
        'the concurrent staging task limit has been reached',
      );
    }

    return store.ensureStaging(transferId, nowMillis: now());
  }

  /// Builds the transient view for one stored record.
  ManifestStaging _viewOf(StagingRecord record) {
    if (!record.isSealed && record.isReleased) {
      throw const ProtocolViolation(
        ProtocolErrorCode.taskExpired,
        'nothing was received for this transfer within §6s thirty-minute window, so the '
        'proposal has been discarded',
      );
    }
    final ManifestStaging staging = store.materialise(record);
    if (record.isSealed) {
      // The digest was verified when the seal was taken and §6 forbids a page changing
      // afterwards, so re-running the seal on the rebuilt view cannot disagree with it.
      staging.seal();
    }
    return staging;
  }

  int _openCount({required bool? sealed}) => store.countOpen(sealed: sealed);
}
