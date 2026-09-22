import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/features/transfer/application/transfer_flow.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';

/// The figures a transfer screen renders, driven the way a real transfer drives them.
///
/// The cases that carry the most weight are the ones where a convenient answer would be wrong:
/// progress advancing on bytes sent rather than chunks the peer acknowledged, a failure wiping the
/// figures, and a phase word invented here instead of taken from the protocol state.
void main() {
  TransferFlow flow({int total = 4 * 1024 * 1024}) =>
      TransferFlow.forTotal(totalBytes: total, atMillis: 0);

  test('a sealed manifest gives a known total and a determinate bar', () {
    final TransferFlow subject = flow();
    expect(subject.phase, TransferPhase.preparing);
    expect(subject.progress.fraction, 0);
    expect(subject.progress.byteLabel, contains('/'));
  });

  test('an unsealed manifest says the total is unknown rather than showing zero of zero', () {
    final TransferFlow subject = TransferFlow.unknownTotal(atMillis: 0);
    expect(
      subject.progress.fraction,
      isNull,
      reason:
          'an indeterminate bar is the honest rendering before the manifest is sealed; a bar '
          'sweeping to completion would claim a proportion nobody knows',
    );
    expect(subject.progress.byteLabel, contains('未知'));
  });

  test(
    'progress advances per acknowledged chunk, not per byte handed to a socket',
    () {
      final TransferFlow subject = flow();

      subject.applyTaskState(TransferState.ready, atMillis: 0);
      expect(
        subject.phase,
        TransferPhase.transferring,
        reason:
            '§10 makes READY the first moment a write generation exists, so it is the first moment '
            'a progress bar means anything',
      );

      subject.applyChunkAcknowledged(
        acknowledged: 1,
        chunkBytes: ProtocolLimits.chunkSizeBytes,
        atMillis: 1000,
      );

      expect(subject.progress.transferredBytes, ProtocolLimits.chunkSizeBytes);
      expect(
        subject.progress.fraction,
        ProtocolLimits.chunkSizeBytes / (4 * 1024 * 1024),
        reason: 'the total is the frozen manifest own total',
      );
      expect(
        subject.progress.bytesPerSecond,
        ProtocolLimits.chunkSizeBytes,
        reason: 'one chunk in one second',
      );
    },
  );

  test(
    'the chunk length comes from the frozen manifest, not from what was sent',
    () {
      // A file whose last chunk is short: reporting it as a full chunk would overstate progress by
      // exactly the bytes that do not exist.
      final TransferFlow subject = TransferFlow.forTotal(
        totalBytes: ProtocolLimits.chunkSizeBytes + 3,
        atMillis: 0,
      );
      subject.applyTaskState(TransferState.transferring, atMillis: 0);
      subject.applyChunkAcknowledged(
        acknowledged: 1,
        chunkBytes: 3,
        atMillis: 1,
      );
      expect(subject.progress.transferredBytes, 3);
      expect(
        subject.progress.transferredBytes,
        lessThan(subject.progress.totalBytes),
        reason: 'the tail chunk is three bytes and the total says four MiB plus three',
      );
    },
  );

  test('a failure keeps the figures and names the reason', () {
    final TransferFlow subject = flow();
    subject.applyTaskState(TransferState.transferring, atMillis: 0);
    subject.applyChunkAcknowledged(
      acknowledged: 2,
      chunkBytes: ProtocolLimits.chunkSizeBytes,
      atMillis: 1000,
    );
    final String before = subject.progress.byteLabel;

    subject.applyFailure('连接已中断', atMillis: 2000);

    expect(subject.phase, TransferPhase.failed);
    expect(subject.progress.failureReason, '连接已中断');
    expect(
      subject.progress.byteLabel,
      before,
      reason:
          '§11 gives several failures a remedy that starts from how far the transfer got, and '
          'blanking the figures would remove exactly that',
    );
  });

  test('a blocked transfer is not shown as a failure', () {
    final TransferFlow subject = flow();
    subject.applyTaskState(TransferState.blocked, atMillis: 0);
    expect(subject.phase, TransferPhase.blocked);
    expect(
      subject.phase.label,
      isNot(TransferPhase.failed.label),
      reason:
          'its exit is a user action - freeing space or changing the location - so telling the '
          'user it failed would be telling them the transfer is over when it is not',
    );
    expect(subject.progress.failureReason, isNull);
  });

  test('a completion stops the rate moving', () {
    final TransferFlow subject = flow();
    subject.applyTaskState(TransferState.transferring, atMillis: 0);
    subject.applyChunkAcknowledged(
      acknowledged: 1,
      chunkBytes: ProtocolLimits.chunkSizeBytes,
      atMillis: 1000,
    );
    subject.applyCompleted(atMillis: 2000);

    expect(subject.phase, TransferPhase.completed);
    expect(subject.progress.phase.canInterrupt, isFalse);
    expect(
      subject.progress.estimatedSecondsRemaining,
      isNull,
      reason: 'a completed transfer has no remaining time to estimate',
    );
  });
}
