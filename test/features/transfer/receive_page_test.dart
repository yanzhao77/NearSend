import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';
import 'package:nearsend/core/storage/saved_file_reference.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/core/storage/task_authorization_repository.dart';
import 'package:nearsend/features/transfer/application/receive_confirmation.dart';
import 'package:nearsend/features/transfer/application/receiving_flow.dart';
import 'package:nearsend/features/transfer/application/server_receiving_flow.dart';
import 'package:nearsend/features/transfer/presentation/receive_page.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';
import 'package:nearsend/platform/storage_location.dart';
import 'package:nearsend/platform/platform_file_actions.dart';

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
    List<SavedFileReference> savedFiles = const <SavedFileReference>[],
    Future<void> Function()? onRefresh,
    Future<List<ReceiveFilePreview>> Function(OfferSummary)? onPreview,
    Future<bool> Function(OfferSummary, ReceiveConfirmation)? onAccept,
    List<ServerOffer> pushOffers = const <ServerOffer>[],
    ServerReceivePhase pushPhase = ServerReceivePhase.waiting,
    SpaceVerdict? pushSpaceVerdict,
    String? pushFailureReason,
    List<String> pushSavedPaths = const <String>[],
    List<SavedFileReference> pushSavedFiles = const <SavedFileReference>[],
    PlatformFileActions? fileActions,
    Future<List<ReceiveFilePreview>> Function(ServerOffer)? onPreviewPush,
    Future<bool> Function(ServerOffer, ReceiveConfirmation)? onAcceptPush,
    StorageLocationRef? initialLocation,
    Future<StorageLocationRef?> Function()? onPickLocation,
    Future<StorageLocationRef> Function(StorageLocationRef)? onValidateLocation,
    void Function(StorageLocationRef)? onRememberDefault,
    Future<SpaceEstimateSnapshot?> Function(ServerOffer, StorageLocationRef)?
    onCheckPushSpace,
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
        savedFiles: savedFiles,
        pushOffers: pushOffers,
        pushPhase: pushPhase,
        pushSpaceVerdict: pushSpaceVerdict,
        pushFailureReason: pushFailureReason,
        pushSavedPaths: pushSavedPaths,
        pushSavedFiles: pushSavedFiles,
        fileActions: fileActions,
        initialLocation: initialLocation,
        onPickLocation: onPickLocation,
        onValidateLocation: onValidateLocation,
        onRememberDefault: onRememberDefault,
        onCheckPushSpace: onCheckPushSpace,
        onAcceptPush: onAcceptPush,
        // Long enough that a test never trips it by accident; the polling behaviour has its own
        // case below.
        refreshInterval: const Duration(seconds: 30),
        onRefresh: onRefresh ?? () async {},
        onPreview:
            onPreview ??
            (OfferSummary offered) async => List<ReceiveFilePreview>.generate(
              offered.fileCount,
              (int index) => ReceiveFilePreview(
                fileId: 'file-$index',
                originalPath: 'received-$index.bin',
                sizeBytes: offered.totalBytes ~/ offered.fileCount,
              ),
            ),
        onPreviewPush:
            onPreviewPush ??
            (ServerOffer offered) async => List<ReceiveFilePreview>.generate(
              offered.fileCount,
              (int index) => ReceiveFilePreview(
                fileId: 'push-file-$index',
                originalPath: 'pushed-$index.bin',
                sizeBytes: offered.totalBytes ~/ offered.fileCount,
              ),
            ),
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
      find.widgetWithText(FilledButton, '接收并保存'),
    );
    expect(accept.onPressed, isNull);

    await unmount(tester);
  });

  testWidgets(
    'a named location makes the offer acceptable, and it is passed on',
    (tester) async {
      OfferSummary? accepted;
      ReceiveConfirmation? confirmation;
      await pump(
        tester,
        phase: ReceivePhase.offered,
        offers: <OfferSummary>[offer],
        onAccept: (OfferSummary o, ReceiveConfirmation selected) async {
          accepted = o;
          confirmation = selected;
          return true;
        },
      );

      await tester.enterText(find.byType(TextField), '  /tmp/received  ');
      await tester.pump();

      final FilledButton accept = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '接收并保存'),
      );
      expect(accept.onPressed, isNotNull);

      await tester.tap(find.widgetWithText(FilledButton, '接收并保存'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '接收并保存').last);
      await tester.pump();

      expect(accepted?.transferId, offer.transferId);
      expect(
        confirmation?.location.opaqueValue,
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
      find.widgetWithText(FilledButton, '接收并保存'),
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

  testWidgets('default opaque location is displayed without exposing its URI', (
    tester,
  ) async {
    const StorageLocationRef location = StorageLocationRef(
      kind: StorageLocationKind.androidDocumentTree,
      opaqueValue: 'content://provider/tree/primary%3ADownload',
      displayName: '下载 / NearSend',
      permissionState: StoragePermissionState.granted,
    );
    await pump(
      tester,
      phase: ReceivePhase.offered,
      offers: <OfferSummary>[offer],
      initialLocation: location,
    );

    expect(find.text('下载 / NearSend'), findsOneWidget);
    expect(find.textContaining('content://'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, '接收并保存'));
    await tester.pump();
    expect(find.text('确认接收文件'), findsOneWidget);
    expect(find.text('下载 / NearSend'), findsWidgets);
    expect(find.textContaining('content://'), findsNothing);
    await unmount(tester);
  });

  testWidgets('multiple output names are confirmed in one modal', (
    tester,
  ) async {
    ReceiveConfirmation? accepted;
    const StorageLocationRef location = StorageLocationRef(
      kind: StorageLocationKind.nativeDirectory,
      opaqueValue: '/tmp/received',
      displayName: 'received',
      permissionState: StoragePermissionState.granted,
    );
    await pump(
      tester,
      phase: ReceivePhase.offered,
      offers: <OfferSummary>[offer],
      initialLocation: location,
      onPreview: (_) async => const <ReceiveFilePreview>[
        ReceiveFilePreview(
          fileId: 'first',
          originalPath: '相册/照片.jpg',
          sizeBytes: 1024,
        ),
        ReceiveFilePreview(
          fileId: 'second',
          originalPath: '报告.pdf',
          sizeBytes: 2048,
        ),
      ],
      onAccept: (_, ReceiveConfirmation confirmation) async {
        accepted = confirmation;
        return true;
      },
    );

    await tester.tap(find.widgetWithText(FilledButton, '接收并保存'));
    await tester.pump();
    expect(find.text('照片.jpg'), findsOneWidget);
    expect(find.text('报告.pdf'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey<String>('receive-output-name-second')),
      '最终报告.pdf',
    );
    await tester.tap(find.widgetWithText(FilledButton, '接收并保存').last);
    await tester.pump();

    expect(accepted?.outputNames, <String, String>{
      'first': '照片.jpg',
      'second': '最终报告.pdf',
    });
    await unmount(tester);
  });

  testWidgets('cancel and invalid names never accept the offer', (
    tester,
  ) async {
    int accepts = 0;
    const StorageLocationRef location = StorageLocationRef(
      kind: StorageLocationKind.nativeDirectory,
      opaqueValue: '/tmp/received',
      displayName: 'received',
    );
    await pump(
      tester,
      phase: ReceivePhase.offered,
      offers: <OfferSummary>[offer],
      initialLocation: location,
      onAccept: (_, _) async {
        accepts++;
        return true;
      },
    );

    await tester.tap(find.widgetWithText(FilledButton, '接收并保存'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pump();
    expect(accepts, 0);

    await tester.tap(find.widgetWithText(FilledButton, '接收并保存'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('receive-output-name-file-0')),
      '../escape.txt',
    );
    await tester.tap(find.widgetWithText(FilledButton, '接收并保存').last);
    await tester.pump();
    expect(find.textContaining('文件名不能包含目录分隔符'), findsOneWidget);
    expect(accepts, 0);
    await unmount(tester);
  });

  testWidgets('revoked location blocks acceptance and offers reselection', (
    tester,
  ) async {
    int accepts = 0;
    const StorageLocationRef location = StorageLocationRef(
      kind: StorageLocationKind.androidDocumentTree,
      opaqueValue: 'content://provider/tree/revoked',
      displayName: '旧目录',
    );
    await pump(
      tester,
      phase: ReceivePhase.offered,
      offers: <OfferSummary>[offer],
      initialLocation: location,
      onPickLocation: () async => null,
      onValidateLocation: (StorageLocationRef selected) async =>
          selected.withPermissionState(StoragePermissionState.denied),
      onAccept: (_, _) async {
        accepts++;
        return true;
      },
    );

    await tester.tap(find.widgetWithText(FilledButton, '接收并保存'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '接收并保存').last);
    await tester.pump();
    expect(find.text('保存位置不可用'), findsOneWidget);
    expect(find.text('重新选择'), findsOneWidget);
    expect(accepts, 0);
    await unmount(tester);
  });

  testWidgets('confirmed location can be persisted as the new default', (
    tester,
  ) async {
    StorageLocationRef? remembered;
    const StorageLocationRef location = StorageLocationRef(
      kind: StorageLocationKind.nativeDirectory,
      opaqueValue: '/tmp/received',
      displayName: 'received',
      permissionState: StoragePermissionState.granted,
    );
    await pump(
      tester,
      phase: ReceivePhase.offered,
      offers: <OfferSummary>[offer],
      initialLocation: location,
      onRememberDefault: (StorageLocationRef selected) {
        remembered = selected;
      },
    );

    await tester.tap(find.widgetWithText(FilledButton, '接收并保存'));
    await tester.pump();
    await tester.tap(find.text('设为默认接收位置'));
    await tester.tap(find.widgetWithText(FilledButton, '接收并保存').last);
    await tester.pump();
    expect(remembered, location);
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
      ReceiveConfirmation? confirmation;
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
        pushSpaceVerdict: SpaceVerdict.sufficient,
        onAcceptPush: (ServerOffer o, ReceiveConfirmation selected) async {
          answered = o;
          confirmation = selected;
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
        find.widgetWithText(FilledButton, '接收并保存'),
        findsNothing,
        reason:
            '§6 keeps the acceptance and the save location together; offering the button before a '
            'location exists would invite a decision that cannot be recorded',
      );

      await tester.enterText(find.byType(TextField), '/tmp/pushed');
      await tester.pump();
      final Finder acceptButton = find.widgetWithText(FilledButton, '接收并保存');
      await tester.ensureVisible(acceptButton);
      await tester.pump();
      await tester.tap(acceptButton);
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '接收并保存').last);
      await tester.pump();

      expect(answered?.transferId, '55555555-6666-4777-8888-999999999999');
      expect(confirmation?.location.opaqueValue, '/tmp/pushed');
      await unmount(tester);
    },
  );

  testWidgets('an unmeasured volume is said out loud, not shown as a pass', (
    tester,
  ) async {
    await pump(
      tester,
      phase: ReceivePhase.idle,
      pushOffers: <ServerOffer>[
        ServerOffer(
          transferId: '77777777-8888-4999-8000-bbbbbbbbbbbb',
          manifestDigest: 'abababababababababababababababababababababababababababababababab',
          direction: TransferDirection.clientToServer,
          fileCount: 1,
          totalBytes: 4 * 1024 * 1024,
        ),
      ],
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
      pushOffers: <ServerOffer>[
        ServerOffer(
          transferId: '77777777-8888-4999-8000-bbbbbbbbbbbb',
          manifestDigest: 'abababababababababababababababababababababababababababababababab',
          direction: TransferDirection.clientToServer,
          fileCount: 1,
          totalBytes: 4 * 1024 * 1024,
        ),
      ],
      pushSpaceVerdict: SpaceVerdict.insufficient,
      onAcceptPush: (_, _) async => true,
    );
    expect(find.text(ReceivePage.spaceInsufficientNote), findsOneWidget);
    await unmount(tester);
  });

  testWidgets(
    'a selected location with unknown space needs acknowledgement before receive',
    (tester) async {
      const ServerOffer pushed = ServerOffer(
        transferId: '88888888-9999-4aaa-8000-cccccccccccc',
        manifestDigest:
            'abababababababababababababababababababababababababababababababab',
        direction: TransferDirection.clientToServer,
        fileCount: 1,
        totalBytes: 1024 * 1024,
      );
      const StorageLocationRef location = StorageLocationRef(
        kind: StorageLocationKind.nativeDirectory,
        opaqueValue: r'C:\workspace\received',
        displayName: 'received',
      );
      int checkCalls = 0;

      await pump(
        tester,
        phase: ReceivePhase.idle,
        pushOffers: const <ServerOffer>[pushed],
        onPickLocation: () async => location,
        onCheckPushSpace: (_, _) async {
          checkCalls++;
          return const SpaceEstimateSnapshot(
            verdict: SpaceVerdict.unknown,
            requiredBytes: 1024 * 1024,
            volumes: <SpaceVolumeSnapshot>[],
          );
        },
        onAcceptPush: (_, _) async => true,
      );

      expect(find.text('接收并保存'), findsNothing);
      final Finder pickLocation = find.text('选择保存位置');
      await tester.ensureVisible(pickLocation);
      await tester.tap(pickLocation);
      await tester.pumpAndSettle();

      expect(checkCalls, 1);
      expect(find.text('received'), findsOneWidget);
      expect(find.text(ReceivePage.spaceUnknownNote), findsOneWidget);
      final Finder acknowledgement = find.text(
        ReceivePage.unknownSpaceAcknowledgement,
      );
      await tester.ensureVisible(acknowledgement);
      await tester.tap(acknowledgement);
      await tester.pump();
      expect(find.text('接收并保存'), findsOneWidget);
      await unmount(tester);
    },
  );

  testWidgets('saved file actions use the real target reference', (
    tester,
  ) async {
    final _RecordingFileActions actions = _RecordingFileActions();
    await pump(
      tester,
      phase: ReceivePhase.saved,
      savedFiles: const <SavedFileReference>[
        SavedFileReference(
          displayName: '报告.txt',
          targetRef: 'content://documents/saved-file',
        ),
      ],
      fileActions: actions,
    );

    expect(find.text('已保存：报告.txt'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '打开'));
    await tester.pump();
    expect(actions.opened, <String>['content://documents/saved-file']);
    expect(find.text('已交给系统打开。'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '显示位置'));
    await tester.pump();
    expect(actions.revealed, <String>['content://documents/saved-file']);
    await unmount(tester);
  });

  testWidgets('missing target references do not offer misleading actions', (
    tester,
  ) async {
    await pump(
      tester,
      phase: ReceivePhase.saved,
      savedFiles: const <SavedFileReference>[
        SavedFileReference(displayName: '仅有显示名称.bin'),
      ],
      fileActions: _RecordingFileActions(),
    );

    expect(find.text('已保存：仅有显示名称.bin'), findsOneWidget);
    expect(find.text('打开'), findsNothing);
    expect(find.text('显示位置'), findsNothing);
    await unmount(tester);
  });

  testWidgets(
    'file action failures are explained without exposing the target',
    (tester) async {
      final _RecordingFileActions actions = _RecordingFileActions(
        openStatus: PlatformFileActionStatus.permissionDenied,
      );
      await pump(
        tester,
        phase: ReceivePhase.saved,
        savedFiles: const <SavedFileReference>[
          SavedFileReference(
            displayName: '私密文件.bin',
            targetRef: 'content://private/opaque-token',
          ),
        ],
        fileActions: actions,
      );

      await tester.tap(find.widgetWithText(TextButton, '打开'));
      await tester.pump();
      expect(find.text('保存位置权限已失效，请重新选择或授权。'), findsOneWidget);
      expect(find.textContaining('opaque-token'), findsNothing);
      await unmount(tester);
    },
  );
}

class _RecordingFileActions implements PlatformFileActions {
  _RecordingFileActions({this.openStatus = PlatformFileActionStatus.completed});

  final PlatformFileActionStatus openStatus;
  final List<String> opened = <String>[];
  final List<String> revealed = <String>[];

  @override
  bool get supportsOpen => true;

  @override
  bool get supportsReveal => true;

  @override
  Future<PlatformFileActionResult> open(String targetRef) async {
    opened.add(targetRef);
    return PlatformFileActionResult(openStatus);
  }

  @override
  Future<PlatformFileActionResult> reveal(String targetRef) async {
    revealed.add(targetRef);
    return const PlatformFileActionResult(PlatformFileActionStatus.completed);
  }
}
