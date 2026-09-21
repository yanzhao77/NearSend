import 'dart:math' as math;

import 'package:nearsend/core/protocol/transfer_state.dart';

/// What the transfer screen is allowed to show, and where each figure comes from.
///
/// `docs/ui/UI_UX_SPEC.md` §5 requires the transfer screen to show the transferred bytes, the
/// total, the current speed and the remaining time, and `AGENTS.md` §2 rule 5 forbids deriving
/// anything from a byte counter that the protocol reserves for the receiver's committed rows.
/// Those two demands meet here, and the resolution is the point of this file:
///
/// * **[transferredBytes] is progress, and its only source is committed bytes.** On a receiver
///   those are its own `chunks` rows; on a sender they are what the receiver last reported. A
///   figure that counted bytes put on the wire would show progress that a crash takes back.
/// * **The speed and the remaining time are derived, and labelled as estimates.** They come from
///   observed deltas over time, so they are computed here rather than stored anywhere - a stored
///   rate would be a second answer to a question that only has observations.
/// * **Nothing here invents a number.** With an unknown total, or fewer than two observations, the
///   estimate is `null` and the UI shows that rather than a placeholder that looks like data.
///
/// The model is deliberately pure: it takes totals and timestamps and produces display figures,
/// so the arithmetic that a user reads as "how long is left" can be tested without a socket.

/// The phase a transfer is in, in words a person can act on.
///
/// These are the distinct states `docs/ui/UI_UX_SPEC.md` §5 asks to be told apart: preparing,
/// scanning, transferring, verifying and exporting are different things, and showing them as one
/// "in progress" would hide the two where the user is waiting for a disk rather than a network.
enum TransferPhase {
  preparing('准备中'),
  waitingAccept('等待对方接受'),
  transferring('传输中'),
  paused('已暂停'),
  checkingResume('正在校验已接收内容'),
  verifying('校验中'),
  exporting('保存中'),
  completed('已完成'),
  failed('失败'),

  /// The link dropped, and §10 gives a resume as the way out rather than a restart.
  interrupted('已中断'),

  /// Something outside the protocol is in the way: permissions, space, a changed source.
  ///
  /// Its exit is a user action - §11 pairs SPACE_INSUFFICIENT with freeing space or changing the
  /// location - so it must not read as a failure.
  blocked('需要处理');

  const TransferPhase(this.label);

  /// A short, localised label. Held next to the value so a screen cannot render a phase it has
  /// no words for.
  final String label;

  /// Whether the transfer is doing work the user is waiting on.
  bool get isActive =>
      this == preparing ||
      this == transferring ||
      this == checkingResume ||
      this == verifying ||
      this == exporting;

  /// Whether the phase can be paused or cancelled.
  bool get canInterrupt =>
      this == preparing || this == transferring || this == waitingAccept;
}

/// One observation of progress, which is all the rate estimate needs.
class _Sample {
  const _Sample(this.atMillis, this.bytes);

  final int atMillis;
  final int bytes;
}

/// How many observations the estimate keeps.
///
/// A short window rather than the whole history: a rate averaged over the whole transfer would
/// take minutes to notice that a link became slow, and the number the user is watching would be
/// wrong exactly when they care.
const int _window = 6;

/// The display model for one transfer.
class TransferProgress {
  TransferProgress._({
    required this.phase,
    required this.totalBytes,
    required this.transferredBytes,
    this.failureReason,
    this._samples = const <_Sample>[],
  });

  /// Starts a transfer at its opening state.
  factory TransferProgress.start({
    required int totalBytes,
    required int atMillis,
  }) => TransferProgress._(
    phase: TransferPhase.preparing,
    totalBytes: totalBytes < 0 ? 0 : totalBytes,
    transferredBytes: 0,
    samples: <_Sample>[_Sample(atMillis, 0)],
  );

  final TransferPhase phase;

  /// The frozen manifest's total. §6 makes the sealed manifest the authority for this, so it is
  /// never the sender's claim in the creation request.
  final int totalBytes;

  /// Committed bytes. See the library comment for what that means on each side.
  final int transferredBytes;

  /// Why it failed, when it did. Already a safe, localised sentence.
  final String? failureReason;

  final List<_Sample> _samples;

  /// A copy with new figures.
  TransferProgress updated({
    TransferPhase? phase,
    int? totalBytes,
    int? transferredBytes,
    int? atMillis,
    String? failureReason,
  }) {
    final int nextTotal = totalBytes ?? this.totalBytes;
    final int nextTransferred = transferredBytes ?? this.transferredBytes;
    final List<_Sample> samples = <_Sample>[..._samples];
    if (atMillis != null) {
      samples.add(_Sample(atMillis, nextTransferred));
      if (samples.length > _window) {
        samples.removeRange(0, samples.length - _window);
      }
    }
    return TransferProgress._(
      phase: phase ?? this.phase,
      totalBytes: nextTotal < 0 ? 0 : nextTotal,
      // A reported figure beyond the manifest's total is clamped rather than shown: it can only
      // come from a disagreement about what the transfer contains, and a progress bar over 100%
      // would be the UI inventing a fact about somebody's file.
      transferredBytes: nextTotal > 0 && nextTransferred > nextTotal
          ? nextTotal
          : nextTransferred,
      samples: samples,
      failureReason: failureReason ?? this.failureReason,
    );
  }

  /// Bytes still to commit, or null when the total is unknown.
  int? get remainingBytes =>
      totalBytes <= 0 ? null : math.max(0, totalBytes - transferredBytes);

  /// Completion in `0..1`, for a determinate bar.
  ///
  /// Returns null when the total is unknown: an indeterminate bar is the honest rendering, and a
  /// bar that swept to completion would claim a proportion nobody knows.
  double? get fraction {
    if (totalBytes <= 0) {
      return null;
    }
    return (transferredBytes / totalBytes).clamp(0.0, 1.0);
  }

  /// Bytes per second, or null when there is not yet an observation that can support one.
  ///
  /// Measured across the oldest and newest sample in the window rather than between the last two:
  /// a single pair of ticks a few hundred milliseconds apart is dominated by scheduling noise, and
  /// the figure a user reads as a speed should not flicker on it.
  double? get bytesPerSecond {
    if (_samples.length < 2) {
      return null;
    }
    final _Sample first = _samples.first;
    final _Sample last = _samples.last;
    final int elapsed = last.atMillis - first.atMillis;
    if (elapsed <= 0) {
      return null;
    }
    final int moved = last.bytes - first.bytes;
    if (moved <= 0) {
      // No progress in the window is a rate of zero, which is a real answer and different from
      // "unknown": a stalled transfer should say 0 B/s rather than show nothing.
      return 0;
    }
    return moved * 1000 / elapsed;
  }

  /// Seconds remaining, or null when it cannot be estimated.
  ///
  /// Null whenever the total, the remainder or the rate is unknown, and also when the rate is
  /// zero - "infinity seconds" is not a time a person can use, and the UI shows a stalled state
  /// instead.
  int? get estimatedSecondsRemaining {
    final int? remaining = remainingBytes;
    final double? rate = bytesPerSecond;
    if (remaining == null || rate == null || rate <= 0) {
      return null;
    }
    return (remaining / rate).ceil();
  }

  /// A localised, human-readable speed, or a dash when it is not yet known.
  String get speedLabel {
    final double? rate = bytesPerSecond;
    if (rate == null) {
      return '—';
    }
    return '${formatBytes(rate.round())}/s';
  }

  /// A localised remaining time, or a phrase that says why there is none.
  String get remainingLabel {
    final int? seconds = estimatedSecondsRemaining;
    if (seconds == null) {
      if (bytesPerSecond == 0) {
        return '已停止（无进展）';
      }
      return '估算中';
    }
    if (seconds < 60) {
      return '约 $seconds 秒';
    }
    final int minutes = seconds ~/ 60;
    if (minutes < 60) {
      return '约 $minutes 分钟';
    }
    final int hours = minutes ~/ 60;
    return '约 $hours 小时 ${minutes % 60} 分钟';
  }

  /// `已传 / 总量`, both in the same units so the pair can be compared at a glance.
  String get byteLabel {
    if (totalBytes <= 0) {
      return '${formatBytes(transferredBytes)} / 未知';
    }
    return '${formatBytes(transferredBytes)} / ${formatBytes(totalBytes)}';
  }

  /// Whether the figures shown describe a transfer that is still moving.
  bool get isStalled =>
      phase == TransferPhase.transferring && bytesPerSecond == 0;
}

/// Formats a byte count with binary units.
///
/// Binary rather than decimal because every figure in this protocol is a byte count a filesystem
/// or a chunk arithmetic produced; showing a 4 MiB chunk as "4.2 MB" would make two numbers in the
/// same screen disagree.
String formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  const List<String> units = <String>['KiB', 'MiB', 'GiB', 'TiB'];
  double value = bytes / 1024;
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  // One decimal below 10 so the difference between 1.5 MiB and 1.9 MiB is visible, and none above
  // it, where the decimal is noise.
  return value >= 10
      ? '${value.round()} ${units[unit]}'
      : '${value.toStringAsFixed(1)} ${units[unit]}';
}

/// The phase the screen should show for a task's protocol state.
///
/// This is the join the UI was missing: `TransferProgress` had a phase and the engine had a
/// `TransferState`, and nothing connected them, so a screen could only ever show what a caller
/// guessed. The switch is exhaustive over [TransferState], so a state added to the protocol fails to
/// compile here rather than rendering as the wrong word.
///
/// Three mappings are worth stating because they are not one-to-one:
///
/// * **`staging` and `preparing` are both 准备中.** §10 keeps them apart because one is sender-local
///   and the other means pages are arriving, but the user is waiting either way and telling them
///   which side is working is not actionable.
/// * **`ready` shows as 传输中.** §10 makes it "accepted and authorised; a write generation
///   exists", which is the first moment bytes may move - so it is the first moment a progress bar
///   means anything, and calling it "preparing" would hide that the transfer has started.
/// * **`interrupted` and `blocked` are their own words** rather than folded into 失败. §10 gives
///   them different exits - a resume and a user action respectively - and §11 pairs `BLOCKED` with
///   "free space or change location, then retry". Showing either as a failure would tell the user the
///   transfer is over when the protocol says it is not.
TransferPhase phaseForTransferState(TransferState state) => switch (state) {
  TransferState.preparing => TransferPhase.preparing,
  TransferState.staging => TransferPhase.preparing,
  TransferState.waitingAccept => TransferPhase.waitingAccept,
  TransferState.ready => TransferPhase.transferring,
  TransferState.transferring => TransferPhase.transferring,
  TransferState.pausing => TransferPhase.paused,
  TransferState.paused => TransferPhase.paused,
  TransferState.checkingResume => TransferPhase.checkingResume,
  TransferState.interrupted => TransferPhase.interrupted,
  TransferState.verifying => TransferPhase.verifying,
  TransferState.exporting => TransferPhase.exporting,
  TransferState.completed => TransferPhase.completed,
  TransferState.partiallyCompleted => TransferPhase.failed,
  TransferState.blocked => TransferPhase.blocked,
  TransferState.failed => TransferPhase.failed,
  TransferState.cancelled => TransferPhase.failed,
};
