import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/features/transfer/application/receiving_flow.dart';
import 'package:nearsend/features/transfer/application/server_receiving_flow.dart';
import 'package:nearsend/features/transfer/presentation/receive_page.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';

/// The receiving screen.
///
/// What it must get right is mostly about **not receiving**: nothing is written anywhere until the
/// user has named a location, the answer to an offer is not offered before there is an offer, and a
/// screen waiting for one says that it is asking rather than looking broken.
void main() {
  const OfferSummary offer = OfferSummary(
    transferId: '22222222-3333-4444-8555-666666666666',
    manifestDigest:
        'abababababababababababababababababababababababababababababababab',
    fileCount: 2,
    totalBytes: 8 * 1024 * 1024,
  );

  Future<void> pump(
    WidgetTester tester, {
    required ReceivePhase phase,
    List<OfferSummary> offers = const <OfferSummary>[],
    TransferProgress? progress,
    String? failureReason,
    List<String> savedPaths = const <String>[],
    Future<void> Function()? onRefresh,
    Future<bool> Function(OfferSummary, String)? onAccept,
    List<ServerOffer> pushOffers = const <ServerOffer>[],
    ServerReceivePhase pushPhase = ServerReceivePhase.waiting,
    SpaceVerdict? pushSpaceVerdict,
    String? pushFailureReason,
    List<String> pushSavedPaths = const <String>[],
    Future<bool> Function(ServerOffer, String)? onAcceptPush,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: buildNearSendTheme(Brightness.light),
      home: ReceivePage(
        phase: phase,
        offers: offers,
        progress: progress,
        fileName: '对方文件.bin',
        fileNumber: 1,
        fileCount: 2,
        failureReason: failureReason,
        savedPaths: savedPaths,
        pushOffers: pushOffers,
        pushPhase: pushPhase,
        pushSpaceVerdict: pushSpaceVerdict,
        pushFailureReason: pushFailureReason,
        pushSavedPaths: pushSavedPaths,
        onAcceptPush: onAcceptPush,
        // Long enough that a test never trips it by accident; the polling behaviour has its own
        // case below.
        refreshInterval: const Duration(seconds: 30),
        onRefresh: onRefresh ?? () async {},
        onAccept: onAccept ?? (_, _) async => true,
      ),
    ),
  );

  /// Unmounts, which is what cancels the poll: a page that keeps asking after it is gone would be a
  /// timer nobody owns.
  Future<void> unmount(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  testWidgets('an offer with no location cannot be accepted', (tester) async {
    await pump(
      tester,
      phase: ReceivePhase.offered,
      offers: <OfferSummary>[offer],
    );

    expect(find.text('2 个文件 · 8.0 MiB'), findsOneWidget);
    expect(
      find.text(ReceivePage.saveLocationRequired),
      findsOneWidget,
      reason:
          '§6 keeps the decision and the save location together; accepting before naming one would '
          'write files somewhere the user never chose',
    );
    final FilledButton accept = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '接受并接收'),
    );
    expect(accept.onPressed, isNull);

    await unmount(tester);
  });

  testWidgets(
    'a named location makes the offer acceptable, and it is passed on',
    (tester) async {
      OfferSummary? accepted;
      String? location;
      await pump(
        tester,
        phase: ReceivePhase.offered,
        offers: <OfferSummary>[offer],
        onAccept: (OfferSummary o, String where) async {
          accepted = o;
          location = where;
          return true;
        },
      );

      await tester.enterText(find.byType(TextField), '  /tmp/received  ');
      await tester.pump();

      final FilledButton accept = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '接受并接收'),
      );
      expect(accept.onPressed, isNotNull);

      await tester.tap(find.widgetWithText(FilledButton, '接受并接收'));
      await tester.pump();

      expect(accepted?.transferId, offer.transferId);
      expect(
        location,
        '/tmp/received',
        reason: 'a path pasted with whitespace is the same path',
      );
      await unmount(tester);
    },
  );

  testWidgets('a screen with nothing offered says it is still asking', (
    tester,
  ) async {
    int refreshes = 0;
    await pump(
      tester,
      phase: ReceivePhase.idle,
      onRefresh: () async => refreshes++,
    );

    expect(find.text(ReceivePage.emptyNote), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, '接受并接收'),
      findsNothing,
      reason: 'there is nothing to accept, and a button for it would be a placeholder',
    );
    expect(
      refreshes,
      greaterThanOrEqualTo(1),
      reason:
          '§6 has no push, so the receiver learns about an offer by asking; a screen that waited '
          'for an event that never arrives is indistinguishable from a broken one',
    );

    await tester.pump(const Duration(seconds: 31));
    expect(refreshes, greaterThanOrEqualTo(2), reason: 'and it keeps asking');
    await unmount(tester);
  });

  testWidgets('the figures during a receive are the ones the flow reported', (
    tester,
  ) async {
    await pump(
      tester,
      phase: ReceivePhase.receiving,
      progress: TransferProgress.start(
        totalBytes: 8 * 1024 * 1024,
        atMillis: 0,
      ).updated(transferredBytes: 2 * 1024 * 1024, atMillis: 1000),
    );

    expect(
      find.text(ReceivePage.phaseLabel(ReceivePhase.receiving)),
      findsOneWidget,
    );
    expect(find.text('2.0 MiB / 8.0 MiB'), findsOneWidget);
    expect(find.text('2.0 MiB/s'), findsOneWidget);
    expect(find.text('对方文件.bin'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a saved file is reported with where it went', (tester) async {
    await pump(
      tester,
      phase: ReceivePhase.saved,
      savedPaths: const <String>['/tmp/received/对方文件.bin'],
    );

    expect(
      find.text(ReceivePage.phaseLabel(ReceivePhase.saved)),
      findsOneWidget,
    );
    expect(
      find.textContaining('/tmp/received/对方文件.bin'),
      findsOneWidget,
      reason: 'the location is what the user chose and the only way they can find the file again',
    );
    await unmount(tester);
  });

  testWidgets('a failure states the reason rather than an empty list', (
    tester,
  ) async {
    await pump(
      tester,
      phase: ReceivePhase.failed,
      failureReason: '接收未能完成：连接可能已中断。',
    );

    expect(find.text('接收未能完成：连接可能已中断。'), findsOneWidget);
    expect(
      find.text(ReceivePage.emptyNote),
      findsNothing,
      reason:
          '"nothing offered" and "the connection failed" are different answers, and the first '
          'would leave the user waiting for something that cannot arrive',
    );
    await unmount(tester);
  });

  testWidgets(
    'a transfer being pushed to this device is shown and answerable',
    (tester) async {
      ServerOffer? answered;
      String? location;
      await pump(
        tester,
        phase: ReceivePhase.idle,
        pushOffers: <ServerOffer>[
          ServerOffer(
            transferId: '55555555-6666-4777-8888-999999999999',
            manifestDigest: 'abababababababababababababababababababababababababababababababab',
            direction: TransferDirection.clientToServer,
            fileCount: 3,
            totalBytes: 4 * 1024 * 1024,
          ),
        ],
        onAcceptPush: (ServerOffer o, String where) async {
          answered = o;
          location = where;
          return true;
        },
      );

      expect(find.text(ReceivePage.pushSectionHeading), findsOneWidget);
      expect(
        find.text('3 个文件 · 4.0 MiB'),
        findsOneWidget,
        reason:
            'the offer is described from the sealed manifest, so the user is deciding about the '
            'transfer they will actually receive',
      );

      // Without a location there is nothing to accept into.
      expect(
        find.widgetWithText(FilledButton, '接受这次发送'),
        findsNothing,
        reason:
            '§6 keeps the acceptance and the save location together; offering the button before a '
            'location exists would invite a decision that cannot be recorded',
      );

      await tester.enterText(find.byType(TextField), '/tmp/pushed');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '接受这次发送'));
      await tester.pump();

      expect(answered?.transferId, '55555555-6666-4777-8888-999999999999');
      expect(location, '/tmp/pushed');
      await unmount(tester);
    },
  );

  testWidgets('an unmeasured volume is said out loud, not shown as a pass', (
    tester,
  ) async {
    await pump(
      tester,
      phase: ReceivePhase.idle,
      pushSpaceVerdict: SpaceVerdict.unknown,
      onAcceptPush: (_, _) async => true,
    );

    expect(
      find.text(ReceivePage.spaceUnknownNote),
      findsOneWidget,
      reason:
          'this build cannot measure a volume, so the screen has to say that no pre-check was '
          'done; silence would be read as "there is enough space"',
    );

    await pump(
      tester,
      phase: ReceivePhase.idle,
      pushSpaceVerdict: SpaceVerdict.insufficient,
      onAcceptPush: (_, _) async => true,
    );
    expect(find.text(ReceivePage.spaceInsufficientNote), findsOneWidget);
    await unmount(tester);
  });
}
