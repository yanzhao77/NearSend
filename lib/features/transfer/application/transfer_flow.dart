import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';

/// The state a transfer screen shows, built from what the protocol actually reports.
///
/// ## What this adds to the pieces around it
///
/// `TransferProgress` knows how to turn byte counts and timestamps into a speed and a remaining
/// time; `phaseForTransferState` knows which word a protocol state deserves. Neither of them is a
/// thing a screen can hold, because a screen also needs to know **when to believe a figure** and
/// **what to do when a step fails**. That is this class, and it is small on purpose: it holds no
/// sockets, no database and no decisions about the transfer itself, so a widget test can drive it
/// through every state a real transfer can reach.
///
/// ## Why progress counts acknowledged chunks rather than bytes
///
/// §9 makes the **receiver's** committed rows the only authority on progress; a sender holds a
/// mirror. So the figure here advances when the peer answers a chunk, never when bytes enter a
/// socket, and [TransferProgress]'s byte count is a sum of the frozen manifest's own chunk lengths -
/// the same lengths the receiver is checking against. A number that counted bytes written to a
/// buffer would keep climbing while the peer refused every one of them.
///
/// ## Why a failure does not erase the progress
///
/// A failed transfer is still something the user may want to resume, and §11 pairs several failures
/// with a retry. Clearing the figures would throw away the one thing that tells them how far it got,
/// so the phase changes and the numbers stay.
class TransferFlow {
  TransferFlow._(this._progress);

  /// Starts a flow for a transfer whose total is known from the frozen manifest.
  factory TransferFlow.forTotal({
    required int totalBytes,
    required int atMillis,
  }) => TransferFlow._(
    TransferProgress.start(totalBytes: totalBytes, atMillis: atMillis),
  );

  /// Starts a flow before the manifest is sealed, when the total is genuinely unknown.
  factory TransferFlow.unknownTotal({required int atMillis}) =>
      TransferFlow._(TransferProgress.start(totalBytes: 0, atMillis: atMillis));

  TransferProgress _progress;

  /// The current figures, for a screen to render.
  TransferProgress get progress => _progress;

  /// The phase the screen should show.
  TransferPhase get phase => _progress.phase;

  /// Applies a protocol state change.
  ///
  /// The mapping is `phaseForTransferState`'s, not a second table: a screen that decided the words
  /// itself would drift from the states the engine actually moves through.
  void applyTaskState(TransferState state, {required int atMillis}) {
    _progress = _progress.updated(
      phase: phaseForTransferState(state),
      atMillis: atMillis,
    );
  }

  /// Records a figure the **peer** reported for how much it has committed.
  ///
  /// Used where this device is the server and the peer pulls: §9 makes the receiver the only
  /// authority on progress, and the mirror is where its reports arrive. Nothing here derives the
  /// number - taking it from anywhere else would be this side inventing the other side's state.
  void applyReportedBytes(int committedBytes, {required int atMillis}) {
    _progress = _progress.updated(
      transferredBytes: committedBytes,
      atMillis: atMillis,
    );
  }

  /// Records that the peer accepted one chunk of a file whose frozen length is [chunkBytes].
  ///
  /// [chunkBytes] comes from the frozen manifest rather than from the bytes that were sent, so a
  /// mismatch between what was sent and what the manifest declares changes nothing here - that
  /// mismatch is the transfer's problem to refuse, not the meter's to hide.
  void applyChunkAcknowledged({
    required int acknowledged,
    required int chunkBytes,
    required int atMillis,
  }) {
    _progress = _progress.updated(
      transferredBytes: acknowledged * chunkBytes,
      atMillis: atMillis,
    );
  }

  /// Records that the transfer stopped with a reason a user can act on.
  ///
  /// The figures are kept deliberately: §11 gives several failures a remedy that starts by looking
  /// at how far the transfer got, and a screen that blanked them would remove exactly that.
  void applyFailure(String reason, {required int atMillis}) {
    _progress = _progress.updated(
      phase: TransferPhase.failed,
      failureReason: reason,
      atMillis: atMillis,
    );
  }

  /// Records that the transfer finished, so the screen stops showing a rate.
  void applyCompleted({required int atMillis}) {
    _progress = _progress.updated(
      phase: TransferPhase.completed,
      atMillis: atMillis,
    );
  }

  @override
  String toString() =>
      'TransferFlow(${_progress.phase.label}, ${_progress.byteLabel})';
}
