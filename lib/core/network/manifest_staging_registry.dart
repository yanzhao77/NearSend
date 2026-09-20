/// Where a transfer's staged manifest pages live while it is being proposed.
///
/// §6's sequence is "`POST /transfers` 创建 staging 任务；分批 `PUT` 文件页和块页；`POST /seal`",
/// so the pages of one transfer accumulate across many requests and have to be reachable by
/// the next one. [ManifestStaging] already holds that accumulation; this is the part that
/// finds the right one and decides whether it may still be used at all.
///
/// ## Why this is process-local, and what that costs
///
/// Nothing here touches SQLite. That is a reading of §6 rather than an oversight: the protocol
/// never says staging must survive a restart, and a restart costs the client a re-upload,
/// which §6 makes safe - "重传相同页返回成功", and pages are stored by index so a duplicate
/// cannot inflate the count. Persisting megabytes of manifest pages to save a re-upload would
/// buy nothing the protocol requires.
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
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

/// The staging state of the transfers this process is proposing.
class ManifestStagingRegistry {
  ManifestStagingRegistry({required this.transfers, int Function()? now})
    : now = now ?? _systemNow;

  /// Reads the declaration a staging session must be built from.
  final TransferRepository transfers;

  /// Clock injection, so a test does not have to wait thirty minutes.
  final int Function() now;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  final Map<String, ManifestStaging> _staging = <String, ManifestStaging>{};

  /// Transfers with staging held in this process.
  int get stagedTransferCount => _staging.length;

  /// Transfers whose manifest has been sealed and is still held.
  int get sealedTransferCount =>
      _staging.values.where((ManifestStaging s) => s.isSealed).length;

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

    final TransferDeclaration? declaration = transfers.readDeclaration(
      transferId,
    );
    if (declaration == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.notFound,
        'no transfer with that id is registered',
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

  /// Forgets a transfer's staging, sealed or not.
  ///
  /// For a cancelled or completed transfer, and for tests. Not called by the expiry check,
  /// which forgets only the proposal it just refused.
  void discard(String transferId) => _staging.remove(transferId);

  /// §6's window, applied where it can actually stop something.
  void _assertStillUsable(String transferId, ManifestStaging staging) {
    if (staging.isSealed) {
      // §6: "不影响已经冻结的任务". A frozen manifest is a conclusion about what arrived; the
      // window is about a proposal nobody finished, and it stops applying here.
      return;
    }
    if (staging.isExpired(nowMillis: now())) {
      _staging.remove(transferId);
      throw const ProtocolViolation(
        ProtocolErrorCode.taskExpired,
        'nothing was received for this transfer within §6s thirty-minute window, so the '
        'proposal has been discarded',
      );
    }
  }
}
