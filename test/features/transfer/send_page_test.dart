import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/features/transfer/application/sending_flow.dart';
import 'package:nearsend/features/transfer/presentation/file_selection_page.dart';
import 'package:nearsend/features/transfer/presentation/send_page.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';

/// The sending screen.
///
/// The rules it has to keep are about **absence**: a control that cannot act is not rendered, and a
/// phase that is a wait is not allowed to look like a hang. Both are asserted by what is on the
/// screen rather than by what a property returns, because the failure this file guards against is a
/// user looking at a screen and drawing the wrong conclusion.
void main() {
  const SelectedFile file = SelectedFile(
    fileId: '00000000-0000-4000-8000-000000000001',
    relativePath: '报告.bin',
    sizeBytes: 8 * 1024 * 1024,
    sourceRef: '/tmp/报告.bin',
  );

  Future<void> pump(
    WidgetTester tester, {
    required SendPhase phase,
    FileSelectionReport? report,
    TransferProgress? progress,
    String? failureReason,
    VoidCallback? onPick,
    void Function(String)? onAddPath,
    VoidCallback? onSend,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: buildNearSendTheme(Brightness.light),
      home: SendPage(
        report: report ?? FileSelectionReport.of(const <SelectedFile>[file]),
        phase: phase,
        progress: progress,
        fileName: '报告.bin',
        fileNumber: 1,
        fileCount: 1,
        failureReason: failureReason,
        onPick: onPick,
        onAddPath: onAddPath,
        onSend: onSend ?? () {},
        onClear: () {},
      ),
    ),
  );

  testWidgets('a document platform gets a picker and no path field', (
    tester,
  ) async {
    await pump(tester, phase: SendPhase.ready, onPick: () {});

    expect(find.text(SendPage.pickHint), findsOneWidget);
    expect(
      find.text('添加'),
      findsNothing,
      reason:
          'a platform whose files are documents has no path to type, and offering the field '
          'would invite a path the platform cannot open',
    );
  });

  testWidgets('a path platform gets the path field and no picker', (
    tester,
  ) async {
    await pump(tester, phase: SendPhase.ready, onAddPath: (_) {});

    expect(find.text('添加'), findsOneWidget);
    expect(
      find.text(SendPage.pickHint),
      findsNothing,
      reason:
          'there is no document picker on this platform, and a button that cannot open one is '
          'the placeholder this project forbids',
    );
  });

  testWidgets(
    'the two waits a user could mistake for a hang say which they are',
    (tester) async {
      await pump(tester, phase: SendPhase.preparing);
      expect(
        find.text(SendPage.phaseLabel(SendPhase.preparing)),
        findsOneWidget,
      );

      await pump(tester, phase: SendPhase.waitingForPeer);
      expect(
        find.text(SendPage.phaseLabel(SendPhase.waitingForPeer)),
        findsOneWidget,
      );
      expect(
        find.text(SendPage.waitingNote),
        findsOneWidget,
        reason:
            'the offer is sealed and the peer has not answered: without this the screen shows a '
            'stillness that reads as a fault in this device',
      );
      expect(
        SendPage.phaseLabel(SendPhase.preparing),
        isNot(SendPage.phaseLabel(SendPhase.waitingForPeer)),
        reason: 'one is local work and the other is the peer, and they are not interchangeable',
      );

      await pump(tester, phase: SendPhase.offeredToPeer);
      expect(
        find.text(SendPage.offeredNote),
        findsOneWidget,
        reason:
            'here the next move is the peer taking the file, which is a third kind of wait and '
            'needs its own sentence rather than the one about a decision',
      );
      expect(
        SendPage.phaseLabel(SendPhase.offeredToPeer),
        isNot(SendPage.phaseLabel(SendPhase.waitingForPeer)),
      );
    },
  );

  testWidgets('the one sending state that may say the peer saved it', (
    tester,
  ) async {
    await pump(tester, phase: SendPhase.savedByPeer);

    expect(
      find.text(SendPage.phaseLabel(SendPhase.savedByPeer)),
      findsOneWidget,
    );
    expect(
      SendPage.phaseLabel(SendPhase.savedByPeer),
      isNot(SendPage.phaseLabel(SendPhase.awaitingVerification)),
      reason:
          'these are different claims: one is "the bytes arrived", the other is "the peer said it '
          'verified and saved them" - and only the second can be believed, because §10 makes the '
          'receiver the side that says it',
    );
    expect(SendPage.phaseLabel(SendPhase.savedByPeer), contains('对方'));
  });

  testWidgets(
    'the figures come from the flow and the action is disabled while busy',
    (tester) async {
      await pump(
        tester,
        phase: SendPhase.sending,
        progress: TransferProgress.start(
          totalBytes: 8 * 1024 * 1024,
          atMillis: 0,
        ).updated(transferredBytes: 4 * 1024 * 1024, atMillis: 1000),
      );

      expect(find.text('4.0 MiB / 8.0 MiB'), findsOneWidget);
      expect(find.text('4.0 MiB/s'), findsOneWidget);
      expect(find.textContaining('约'), findsOneWidget);

      final FilledButton send = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '传输中…'),
      );
      expect(
        send.onPressed,
        isNull,
        reason:
            'a second send while one is in flight would propose a second transfer for the same '
            'selection',
      );
    },
  );

  testWidgets('arrival is not reported as completion', (tester) async {
    await pump(
      tester,
      phase: SendPhase.awaitingVerification,
      progress: TransferProgress.start(totalBytes: 100, atMillis: 0).updated(
        transferredBytes: 100,
        atMillis: 1000,
        phase: TransferPhase.completed,
      ),
    );

    final String label = SendPage.phaseLabel(SendPhase.awaitingVerification);
    expect(
      label,
      isNot('已完成'),
      reason:
          'all chunks acknowledged means the bytes arrived; verifying and saving are the '
          'receiver\'s work, and §7 says a successful download is not receiver persistence',
    );
    expect(label, contains('对方'));
    expect(
      label,
      contains('校验'),
      reason: 'the screen must name what is still outstanding, not merely avoid the word 完成',
    );
  });

  testWidgets('a failure states the reason and offers the action again', (
    tester,
  ) async {
    await pump(
      tester,
      phase: SendPhase.failed,
      failureReason: '传输未能完成：连接可能已中断。',
    );

    expect(find.text('传输未能完成：连接可能已中断。'), findsOneWidget);
    expect(
      find.text('重新发送'),
      findsOneWidget,
      reason: 'a failure with no way forward leaves the user with a selection they cannot use',
    );
  });

  testWidgets('keeps the extension visible for a long selected filename', (
    tester,
  ) async {
    const SelectedFile longFile = SelectedFile(
      fileId: '00000000-0000-4000-8000-000000000003',
      relativePath: 'directory/another-directory/very-long-report-name-that-must-stay-readable.tar.gz',
      sizeBytes: 128,
      sourceRef: '/tmp/long-report.tar.gz',
    );
    await pump(
      tester,
      phase: SendPhase.ready,
      report: FileSelectionReport.of(const <SelectedFile>[longFile]),
    );

    expect(find.textContaining('.gz'), findsOneWidget);
  });

  testWidgets('does not show network speed during verification', (
    tester,
  ) async {
    await pump(
      tester,
      phase: SendPhase.awaitingVerification,
      progress: TransferProgress.start(totalBytes: 100, atMillis: 0).updated(
        phase: TransferPhase.verifying,
        transferredBytes: 100,
        atMillis: 1000,
      ),
    );

    expect(find.text('速度'), findsNothing);
    expect(find.text('剩余时间'), findsNothing);
    expect(
      find.text(SendPage.phaseLabel(SendPhase.awaitingVerification)),
      findsOneWidget,
    );
  });

  testWidgets('an empty selection says so and cannot be sent', (tester) async {
    await pump(
      tester,
      phase: SendPhase.empty,
      report: FileSelectionReport.of(const <SelectedFile>[]),
    );

    expect(find.text(SendPage.emptyNote), findsOneWidget);
    final FilledButton send = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '发送'),
    );
    expect(send.onPressed, isNull);
  });

  test(
    'a selection beyond the protocol limit is refused before anything starts',
    () {
      // §5's chunk limit is the one a user can reach with ordinary files: 4 MiB chunks and a
      // transfer bound mean a very large multi-file selection is refused here rather than after the
      // manifest upload.
      final SelectedFile huge = SelectedFile(
        fileId: '00000000-0000-4000-8000-000000000002',
        relativePath: 'huge.bin',
        // One chunk past the transfer's limit, so the refusal is about the count rather than about
        // a rounding that happened to land exactly on the bound.
        sizeBytes:
            (ProtocolLimits.maxChunksPerTransfer + 1) *
            ProtocolLimits.chunkSizeBytes,
        sourceRef: '/tmp/huge.bin',
      );
      final FileSelectionReport report = FileSelectionReport.of(<SelectedFile>[
        huge,
      ]);
      expect(report.canSend, isFalse);
      expect(report.problems.join('|'), contains('分块总数超过上限'));
    },
  );
}
