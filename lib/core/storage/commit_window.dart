/// §8's batch checkpoint window: how much verified work may wait for a commit, and when
/// it must stop waiting.
///
/// ## Why this exists at all
///
/// §8 allows a receiver to answer a chunk `PUT` with `verified_pending` instead of
/// `committed`, and says why: "verified_pending 只证明本次块长度/摘要正确，**不可释放持久化
/// 确认跟踪**". The bytes are on disk and digest-verified, but no chunk row is committed, so
/// the checkpoint has not moved.
///
/// That is a deliberate trade. Committing every chunk separately costs a transaction per
/// 4 MiB; batching costs the work done since the last checkpoint whenever the process dies
/// mid-window. §8 bounds that loss twice over - never more than
/// [ProtocolLimits.maxPendingCheckpointBytes] of verified data, and never more than
/// [ProtocolLimits.checkpointIntervalMillis] of waiting - and forces a commit at the pause
/// and file-end boundaries, which are exactly the moments a checkpoint is cheap to take.
///
/// ## What is deliberately *not* here
///
/// There is no third chunk state. `chunks.state` stays `missing`/`committed`, because
/// "written but not committed" is not progress: `AGENTS.md` §2 rule 5 makes the committed
/// row the only authority, and a `verifying` state would be a second answer to "how far did
/// we get". `verified_pending` is a *response*, not a stored state, so a crash inside a
/// window leaves the chunks `missing` and they are simply re-sent.
///
/// The window holds receipts, not just indices. The batch commit re-checks each receipt
/// against the frozen manifest inside its transaction, so a caller that enqueues an index
/// it never verified cannot commit it - the same reason
/// [ChunkRepository.commitChunkAfterSync] verified before committing.
library;

import 'package:nearsend/core/protocol/protocol_limits.dart';

/// One chunk's proof that it was written, digest-verified and durably synced.
///
/// The digest travels with the index so the commit can re-check it. Dropping it here and
/// trusting the index alone would make the batch commit a way to mark any registered chunk
/// committed without evidence.
class PendingChunkCommit {
  const PendingChunkCommit({
    required this.index,
    required this.lengthBytes,
    required this.sha256,
  });

  /// The chunk's index within its file.
  final int index;

  /// Length reported by the sink.
  final int lengthBytes;

  /// Lowercase hexadecimal SHA-256 reported by the sink.
  final String sha256;

  @override
  String toString() =>
      'PendingChunkCommit($index ${lengthBytes}B ${sha256.substring(0, 8)}...)';
}

/// What the caller must do around one arriving chunk.
class WindowPlan {
  const WindowPlan({required this.flushBefore});

  /// Whether the pending batch must be committed *before* this chunk is written.
  ///
  /// True when the window could not hold the chunk without exceeding §8's bound, or when
  /// the pending data is already past §8's time limit. Flushing first is what keeps the
  /// buffer bounded: with a 16 MiB window and 4 MiB chunks the fifth chunk meets a full
  /// window rather than a window that grows to 20 MiB.
  final bool flushBefore;

  @override
  String toString() => 'WindowPlan(flushBefore: $flushBefore)';
}

/// §8's bounds, as a value.
///
/// Held separately from [ChunkCommitWindow] so the policy is shared and immutable while the
/// window carries state, and so a test can drive the window with a small bound instead of
/// moving 16 MiB of bytes.
class CommitWindowPolicy {
  const CommitWindowPolicy({
    this.maxPendingBytes = ProtocolLimits.maxPendingCheckpointBytes,
    this.flushIntervalMillis = ProtocolLimits.checkpointIntervalMillis,
    this.chunkSizeBytes = ProtocolLimits.chunkSizeBytes,
  });

  /// §8's single-chunk policy: write one chunk, then checkpoint it.
  ///
  /// A zero interval means "due as soon as anything is pending", which reproduces the
  /// per-chunk transaction the storage layer used before the batch window existed. It
  /// exists so that path is *implemented by* the window rather than beside it.
  static const CommitWindowPolicy immediate = CommitWindowPolicy(
    maxPendingBytes: ProtocolLimits.chunkSizeBytes,
    flushIntervalMillis: 0,
  );

  /// Most verified-but-uncommitted bytes the window may hold.
  final int maxPendingBytes;

  /// How long pending data may wait for a checkpoint.
  final int flushIntervalMillis;

  /// The chunk size the window is sized for.
  ///
  /// The window refuses to admit a chunk larger than [maxPendingBytes], and with §5's
  /// 4 MiB chunks and a 16 MiB window that can never happen. Sizing the window below one
  /// chunk would make every chunk unadmittable, so it is rejected at construction rather
  /// than discovered as a hang.
  final int chunkSizeBytes;
}

/// The batches one file is accumulating toward its next checkpoint (§8).
///
/// One window belongs to one file: §8 serialises writes per file ("每文件串行写入"), and a
/// window shared across files would let one file's flush commit another file's receipts
/// under an index space the caller never checked.
///
/// The window never performs a commit and never writes bytes. It answers two questions -
/// what to do before writing, and whether a checkpoint is due - and records receipts. That
/// keeps it testable without a database, a sink or a socket.
class ChunkCommitWindow {
  ChunkCommitWindow({this.policy = const CommitWindowPolicy()}) {
    if (policy.maxPendingBytes <= 0) {
      throw ArgumentError.value(
        policy.maxPendingBytes,
        'policy.maxPendingBytes',
        'the window must be able to hold something',
      );
    }
    if (policy.maxPendingBytes < policy.chunkSizeBytes) {
      throw ArgumentError.value(
        policy.maxPendingBytes,
        'policy.maxPendingBytes',
        '§8 requires the window to hold at least one chunk '
            '(${policy.chunkSizeBytes} bytes)',
      );
    }
    if (policy.flushIntervalMillis < 0) {
      throw ArgumentError.value(
        policy.flushIntervalMillis,
        'policy.flushIntervalMillis',
        'an interval cannot be negative',
      );
    }
  }

  final CommitWindowPolicy policy;

  final List<PendingChunkCommit> _pending = <PendingChunkCommit>[];
  int _pendingBytes = 0;

  /// When the current window began filling, or null when it is empty.
  ///
  /// §8's second runs "每 ... 1 秒 checkpoint" from the moment there is something to
  /// persist, not from the last flush, so an idle receiver does not checkpoint nothing.
  int? _windowStartedAtMillis;

  /// Verified-but-uncommitted receipts, in arrival order.
  List<PendingChunkCommit> get pending =>
      List<PendingChunkCommit>.unmodifiable(_pending);

  /// Bytes waiting for a checkpoint.
  int get pendingBytes => _pendingBytes;

  /// Whether anything is waiting.
  bool get hasPending => _pending.isNotEmpty;

  /// Decides what must happen before [lengthBytes] is written.
  ///
  /// Does not change the window, so the caller can flush, fail and retry with the same
  /// answer. The admission itself is [enqueue], which is only correct after a sink has
  /// reported a successful durable sync.
  WindowPlan plan({required int lengthBytes, required int nowMillis}) {
    if (lengthBytes < 0) {
      throw ArgumentError.value(
        lengthBytes,
        'lengthBytes',
        'cannot be negative',
      );
    }
    if (lengthBytes > policy.maxPendingBytes) {
      // Unreachable with §5's chunk size and §8's window, and not a peer's fault if it
      // ever happened: it would mean this build was configured to hold less than one
      // chunk, which [ChunkCommitWindow] already refuses at construction.
      throw ArgumentError.value(
        lengthBytes,
        'lengthBytes',
        'a chunk larger than the whole window cannot be admitted',
      );
    }
    final int? startedAt = _windowStartedAtMillis;
    final bool wouldOverflow =
        _pendingBytes + lengthBytes > policy.maxPendingBytes;
    final bool overdue =
        startedAt != null &&
        nowMillis - startedAt >= policy.flushIntervalMillis;
    return WindowPlan(flushBefore: wouldOverflow || overdue);
  }

  /// Records a verified chunk and reports the resulting window size.
  ///
  /// Throws [StateError] if the receipt would push the window past §8's bound. That is a
  /// programming error rather than a peer error - it means [plan] was ignored - and it is
  /// loud on purpose: silently accepting the receipt would let the bound drift upward
  /// exactly when a caller is misusing the window.
  void enqueue(PendingChunkCommit receipt, {required int nowMillis}) {
    if (_pendingBytes + receipt.lengthBytes > policy.maxPendingBytes) {
      throw StateError(
        '§8 bounds the pending window at ${policy.maxPendingBytes} bytes, but '
        '${_pendingBytes + receipt.lengthBytes} would be held; plan() said to flush '
        'first and was not followed',
      );
    }
    _pending.add(receipt);
    _pendingBytes += receipt.lengthBytes;
    _windowStartedAtMillis ??= nowMillis;
  }

  /// Whether §8 requires a checkpoint now.
  ///
  /// [forced] is the caller reporting a pause or a file end: §8 makes those boundaries
  /// mandatory rather than waiting for the bound, because they are the moments at which
  /// the answer stops changing.
  bool isCheckpointDue({required int nowMillis, bool forced = false}) {
    if (_pending.isEmpty) {
      return false;
    }
    if (forced) {
      return true;
    }
    if (_pendingBytes >= policy.maxPendingBytes) {
      return true;
    }
    final int? startedAt = _windowStartedAtMillis;
    return startedAt != null &&
        nowMillis - startedAt >= policy.flushIntervalMillis;
  }

  /// Clears the window after a successful batch commit.
  ///
  /// Must be called only after the transaction committed. A failed commit leaves the
  /// receipts in place so the same batch is retried - the bytes are still synced on disk,
  /// and dropping the receipts would leave chunk rows `missing` that nothing would ever
  /// revisit until a resume re-sent them.
  void markFlushed() {
    _pending.clear();
    _pendingBytes = 0;
    _windowStartedAtMillis = null;
  }

  @override
  String toString() =>
      'ChunkCommitWindow(${_pending.length} pending, $_pendingBytes bytes)';
}
