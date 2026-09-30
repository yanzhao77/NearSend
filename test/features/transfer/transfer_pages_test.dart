import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/features/transfer/presentation/transfer_pages.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';

/// The transfer screen's figures.
///
/// `docs/ui/UI_UX_SPEC.md` §5 asks for the transferred and total bytes, the speed and the
/// remaining time, and `AGENTS.md` §2 rule 5 forbids deriving recovery from a byte counter. The
/// cases below are about the second constraint as much as the first: what the screen shows when a
/// figure is *not* known, and what it must never show.
void main() {
  group('protocol state to phase', _phaseMappingTests);

  group('progress figures', () {
    test('a fraction needs a known total', () {
      final TransferProgress unknown = TransferProgress.start(
        totalBytes: 0,
        atMillis: 0,
      );
      expect(
        unknown.fraction,
        isNull,
        reason:
            'an unknown total must produce no proportion, so the bar stays indeterminate '
            'instead of sweeping to a completion nobody knows',
      );
      expect(unknown.remainingBytes, isNull);
      expect(unknown.remainingLabel, '估算中');
    });

    test('speed needs two observations', () {
      final TransferProgress one = TransferProgress.start(
        totalBytes: 1000,
        atMillis: 0,
      );
      expect(
        one.bytesPerSecond,
        isNull,
        reason:
            'one sample is not a rate, and showing one would be inventing it',
      );

      final TransferProgress two = one.updated(
        transferredBytes: 500,
        atMillis: 1000,
      );
      expect(two.bytesPerSecond, 500);
      expect(two.speedLabel, '500 B/s');
      expect(two.estimatedSecondsRemaining, 1);
    });

    test('no progress in the window is zero, which is not unknown', () {
      final TransferProgress stalled =
          TransferProgress.start(totalBytes: 1000, atMillis: 0).updated(
            phase: TransferPhase.transferring,
            transferredBytes: 0,
            atMillis: 2000,
          );

      expect(
        stalled.bytesPerSecond,
        0,
        reason:
            'a stalled transfer must say so rather than showing nothing, which would read as '
            '"still measuring"',
      );
      expect(stalled.isStalled, isTrue);
      expect(
        stalled.estimatedSecondsRemaining,
        isNull,
        reason: 'infinity seconds is not a time a person can use',
      );
      expect(stalled.remainingLabel, '已停止（无进展）');
    });

    test('a reported figure beyond the total is clamped, never shown over 100%', () {
      final TransferProgress over = TransferProgress.start(
        totalBytes: 100,
        atMillis: 0,
      ).updated(transferredBytes: 500, atMillis: 10);

      expect(over.transferredBytes, 100);
      expect(
        over.fraction,
        1.0,
        reason:
            'a figure over the manifest total can only come from a disagreement about what '
            'the transfer contains, and the screen must not repeat it as fact',
      );
    });

    test('the phase words distinguish the states a user is waiting on', () {
      expect(TransferPhase.preparing.isActive, isTrue);
      expect(
        TransferPhase.verifying.isActive,
        isTrue,
        reason:
            '校验中 is a disk wait, not a network one, and must be its own state',
      );
      expect(TransferPhase.completed.canInterrupt, isFalse);
      expect(TransferPhase.failed.canInterrupt, isFalse);
      expect(TransferPhase.transferring.canInterrupt, isTrue);
    });

    test(
      'byte formatting uses binary units so two figures on one screen agree',
      () {
        expect(formatBytes(512), '512 B');
        expect(formatBytes(1024), '1.0 KiB');
        expect(formatBytes(4 * 1024 * 1024), '4.0 MiB');
        expect(formatBytes(20 * 1024 * 1024 * 1024), '20 GiB');
      },
    );
  });

  group('transfer screen', () {
    Future<void> pump(WidgetTester tester, TransferProgress progress) =>
        tester.pumpWidget(
          MaterialApp(
            theme: buildNearSendTheme(Brightness.light),
            home: TransferDetailPage(
              progress: progress,
              fileName: 'a.bin',
              onPause: () {},
              onResume: () {},
              onCancel: () {},
              onRetry: () {},
            ),
          ),
        );

    testWidgets('shows the status word and the three figures', (tester) async {
      final TransferProgress progress =
          TransferProgress.start(
            totalBytes: 8 * 1024 * 1024,
            atMillis: 0,
          ).updated(
            phase: TransferPhase.transferring,
            transferredBytes: 4 * 1024 * 1024,
            atMillis: 1000,
          );
      await pump(tester, progress);

      expect(find.text('传输中'), findsOneWidget);
      expect(find.text('4.0 MiB / 8.0 MiB'), findsOneWidget);
      expect(find.text('4.0 MiB/s'), findsOneWidget);
      expect(find.textContaining('约'), findsOneWidget);
    });

    testWidgets('offers pause and cancel while transferring, and no resume', (
      tester,
    ) async {
      final TransferProgress progress = TransferProgress.start(
        totalBytes: 100,
        atMillis: 0,
      ).updated(phase: TransferPhase.transferring);
      await pump(tester, progress);

      expect(find.text('暂停'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(
        find.text('继续'),
        findsNothing,
        reason: 'a control that cannot apply is absent rather than disabled and confusing',
      );
    });

    testWidgets('offers resume when paused and retry when failed', (
      tester,
    ) async {
      await pump(
        tester,
        TransferProgress.start(
          totalBytes: 100,
          atMillis: 0,
        ).updated(phase: TransferPhase.paused),
      );
      expect(find.text('继续'), findsOneWidget);

      await pump(
        tester,
        TransferProgress.start(
          totalBytes: 100,
          atMillis: 0,
        ).updated(phase: TransferPhase.failed, failureReason: '连接已中断'),
      );
      expect(find.text('重试'), findsOneWidget);
      expect(
        find.text('连接已中断'),
        findsOneWidget,
        reason:
            'a failure must say why, and the reason is already a safe sentence',
      );
    });

    testWidgets('an unknown total draws an indeterminate bar', (tester) async {
      await pump(tester, TransferProgress.start(totalBytes: 0, atMillis: 0));
      final LinearProgressIndicator bar = tester
          .widget<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          );
      expect(bar.value, isNull);
    });
  });
}

/// The join between the protocol's task states and the words the screen shows.
///
/// `TransferProgress` had a phase and the engine had a `TransferState`, and nothing connected them,
/// so a screen could only show what its caller guessed. These cases pin the mapping, and the most
/// important ones are the two the protocol explicitly says are **not** failures: §11 pairs `BLOCKED`
/// with "free space or change the location, then retry", and `INTERRUPTED` has a resume as its exit -
/// rendering either as 失败 would tell the user the transfer is over when it is not.
void _phaseMappingTests() {
  test('every task state maps to a phase, and the two recoverable ones are not failures', () {
    expect(phaseForTransferState(TransferState.blocked), TransferPhase.blocked);
    expect(
      phaseForTransferState(TransferState.interrupted),
      TransferPhase.interrupted,
    );
    expect(
      TransferPhase.blocked.label,
      isNot(TransferPhase.failed.label),
      reason: 'a blocked transfer is waiting on the user, not over',
    );
    expect(TransferPhase.interrupted.canInterrupt, isFalse);
    expect(
      TransferPhase.blocked.canInterrupt,
      isFalse,
      reason: '§10 gives blocked a user action as its exit, not a pause',
    );
  });

  test('the states a user cannot tell apart collapse to one word', () {
    expect(
      phaseForTransferState(TransferState.preparing),
      phaseForTransferState(TransferState.staging),
      reason:
          'one is sender-local and the other means pages are arriving, but the user is waiting '
          'either way and which side is working is not actionable',
    );
    expect(phaseForTransferState(TransferState.pausing), TransferPhase.paused);
    expect(
      phaseForTransferState(TransferState.ready),
      TransferPhase.transferring,
      reason:
          '§10 makes READY the first moment a write generation exists, so it is the first moment '
          'a progress bar means anything',
    );
  });

  test(
    'the two states with real work left are distinct from the transfer itself',
    () {
      // §5 wants 校验中 and 保存中 to be told apart from 传输中: they are disk waits, and a user
      // watching a stalled bar deserves to know which one is slow.
      expect(
        phaseForTransferState(TransferState.verifying),
        TransferPhase.verifying,
      );
      expect(
        phaseForTransferState(TransferState.exporting),
        TransferPhase.exporting,
      );
      expect(TransferPhase.verifying.isActive, isTrue);
      expect(TransferPhase.exporting.isActive, isTrue);
    },
  );

  test('a partial completion is reported as a failure rather than as done', () {
    expect(
      phaseForTransferState(TransferState.partiallyCompleted),
      TransferPhase.failed,
      reason:
          'some files are not on the receiver disk; calling that 已完成 is the false completion '
          'AGENTS.md §2 rule 11 forbids',
    );
    expect(
      phaseForTransferState(TransferState.cancelled),
      TransferPhase.failed,
    );
  });
}
