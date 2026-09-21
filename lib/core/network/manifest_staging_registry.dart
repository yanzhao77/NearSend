/// Where a transfer's staged manifest pages live while it is being proposed.
///
/// §6's sequence is "`POST /transfers` 创建 staging 任务；分批 `PUT` 文件页和块页；`POST /seal`",
/// so the pages of one transfer accumulate across many requests and have to be reachable by
/// the next one. [ManifestStaging] already holds that accumulation; this is the part that
/// finds the right one and decides whether it may still be used at all.
///
/// ## Why the first build is process-local, and what that costs
///
/// Nothing here touches SQLite yet. ADR-0004 requires production staging to be persisted;
/// this registry is only the bounded first-demo implementation. A restart costs the client a
/// re-upload, which §6 makes safe - "重传相同页返回成功" - but that does not make restart recovery
/// an implemented feature.
///
/// The cost is stated plainly: **a sealed manifest from before a restart is gone**, so the
/// chunk endpoints will need the client to re-upload and re-seal. Persisting the frozen
/// manifest is a separate decision, and until it is taken this build must not claim that a
/// transfer survives a server restart.
///
/// ## §6's thirty-minute window finally has an executor
///
/// §6: "首次收到内容后 30 分钟 staging 未完成则清理并撤销该提议；**不影响已经冻结的任务**".
/// `ManifestStaging.isExpired` was only a predicate with nothing calling it. It is enforced at
/// the point of use here - a page or a seal against an expired proposal is refused - and it
/// stops applying once the manifest is frozen, which is the half the sentence is emphatic
/// about. A proposal nobody came back to is simply forgotten.
library;

import 'package:nearsend/core/protocol/manifest_staging.dart';
import 'package:nearsend/core/protocol/manifest_page.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

/// The staging state of the transfers this process is proposing.
enum StagingReleaseReason { sealed, cancelled, failed }

class ManifestStagingRegistry {
  ManifestStagingRegistry({
    required this.transfers,
    int Function()? now,
    this.maxConcurrentTransfers = 8,
    this.maxRetainedEntries = 262144,
  }) : assert(maxConcurrentTransfers > 0),
       assert(maxRetainedEntries > 0),
       now = now ?? _systemNow;

  /// Reads the declaration a staging session must be built from.
  final TransferRepository transfers;

  /// Clock injection, so a test does not have to wait thirty minutes.
  final int Function() now;

  /// Maximum number of manifests held by the demo process at once.
  final int maxConcurrentTransfers;

  /// Maximum retained file + chunk records across all process-local manifests.
  ///
  /// Record fields have protocol bounds, so this is the enforceable heap-growth budget;
  /// production replaces it with SQLite-backed paging rather than raising it without limit.
  final int maxRetainedEntries;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  final Map<String, ManifestStaging> _staging = <String, ManifestStaging>{};
  final Set<String> _expired = <String>{};

  /// Transfers with staging held in this process.
  int get stagedTransferCount => _staging.length;

  /// Transfers whose manifest has been sealed and is still held.
  int get sealedTransferCount =>
      _staging.values.where((ManifestStaging s) => s.isSealed).length;

  int get retainedEntryCount => _staging.values.fold<int>(
    0,
    (int total, ManifestStaging staging) => total + staging.stagedEntryCount,
  );

  /// The staging for [transferId], created from the stored declaration on first use.
  ///
  /// Throws `NOT_FOUND` when no such transfer exists - §7 answers an unknown or unauthorised
  /// resource the same way, and a client cannot use this to learn which transfer ids exist.
  /// Throws `TASK_EXPIRED` when §6's window has run out on a proposal that is still
  /// incomplete.
  ManifestStaging stagingFor(String transferId) {
    final ManifestStaging? existing = _staging[transferId];
    if (existing != null) {
      _assertStillUsable(transferId, existing);
      return existing;
    }

    _purgeExpired();
    if (_expired.contains(transferId)) {
      throw const ProtocolViolation(
        ProtocolErrorCode.taskExpired,
        'the incomplete staging proposal has expired',
      );
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
    if (_staging.length >= maxConcurrentTransfers) {
      throw const ProtocolViolation(
        ProtocolErrorCode.resourceLimit,
        'the process-local staging task limit has been reached',
      );
    }
    final String? digest = declaration.manifestDigest;
    if (digest == null) {
      // §7's creation carries the digest, so a transfer without one was not created by this
      // build. Refusing is the honest answer: there is nothing to verify pages against.
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidState,
        'the transfer has no declared manifest digest, so no page can be checked against it',
      );
    }

    final ManifestStaging created = ManifestStaging(
      transferId: transferId,
      manifestDigest: digest,
      protocolMajor: declaration.protocolMajor,
      protocolMinor: declaration.protocolMinor,
    );
    _staging[transferId] = created;
    return created;
  }

  /// Adds a page while enforcing the process-wide retained-record budget.
  PageAcceptance addPage(
    String transferId,
    ManifestPage page, {
    int? nowMillis,
  }) {
    final ManifestStaging target = stagingFor(transferId);
    final PageAcceptance acceptance = target.addPage(
      page,
      nowMillis: nowMillis ?? now(),
    );
    if (retainedEntryCount > maxRetainedEntries) {
      // This proposal failed its resource contract. Keeping its partial heap would allow a
      // peer to pin the process at the limit; the client may start it again in smaller pages.
      _staging.remove(transferId);
      throw const ProtocolViolation(
        ProtocolErrorCode.resourceLimit,
        'the process-local manifest staging memory budget has been reached',
      );
    }
    return acceptance;
  }

  /// Forgets a transfer's staging, sealed or not.
  ///
  /// For a cancelled or completed transfer, and for tests. Not called by the expiry check,
  /// which forgets only the proposal it just refused.
  void discard(String transferId) => _staging.remove(transferId);

  /// Releases process-local staging after a terminal lifecycle event.
  ///
  /// A retryable seal validation error is deliberately not terminal: its pages stay available
  /// so the sender can supply what is missing. Sealed/cancelled/terminally failed tasks must
  /// use this method so the registry cannot grow for the lifetime of the process.
  void release(String transferId, StagingReleaseReason reason) {
    _staging.remove(transferId);
  }

  void _purgeExpired() {
    final int moment = now();
    _staging.removeWhere((String transferId, ManifestStaging staging) {
      final bool expired =
          !staging.isSealed && staging.isExpired(nowMillis: moment);
      if (expired) {
        _expired.add(transferId);
      }
      return expired;
    });
  }

  /// §6's window, applied where it can actually stop something.
  void _assertStillUsable(String transferId, ManifestStaging staging) {
    if (staging.isSealed) {
      // §6: "不影响已经冻结的任务". A frozen manifest is a conclusion about what arrived; the
      // window is about a proposal nobody finished, and it stops applying here.
      return;
    }
    if (staging.isExpired(nowMillis: now())) {
      _staging.remove(transferId);
      _expired.add(transferId);
      throw const ProtocolViolation(
        ProtocolErrorCode.taskExpired,
        'nothing was received for this transfer within §6s thirty-minute window, so the '
        'proposal has been discarded',
      );
    }
  }
}
