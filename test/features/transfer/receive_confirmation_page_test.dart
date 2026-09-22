import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/core/storage/space_plan.dart';
import 'package:nearsend/core/storage/task_authorization_repository.dart';
import 'package:nearsend/features/transfer/presentation/receive_confirmation_page.dart';

/// The receive confirmation and its space check.
///
/// `技术方案 V2.1` §16.2 is the constraint these cases exist for: the plan must carry its
/// explanations, and an unverifiable volume must **never** render as a passed check. A screen that
/// showed a green tick for `unknown` would convert a risk the user was supposed to accept into an
/// assurance nobody gave.
///
/// The assertions read the page's own decision properties and the status line it renders, rather
/// than counting button labels: the decision is the thing that must be right, and a label can be
/// reworded without the rule changing.
void main() {
  SpaceEstimateSnapshot snapshotFor({required int? freeBytes}) {
    final SpacePlan plan = SpacePlanner().plan(
      files: <FileSpaceRequest>[
        const FileSpaceRequest(
          fileId: '00000000-0000-4000-8000-000000000001',
          sizeBytes: 4 * 1024 * 1024,
          stagingVolume: VolumeId('staging'),
          exportVolume: VolumeId('internal'),
        ),
      ],
      availability: <VolumeId, VolumeAvailability>{
        const VolumeId('staging'): freeBytes == null
            ? const VolumeAvailability.unknown()
            : VolumeAvailability.known(freeBytes),
        const VolumeId('internal'): freeBytes == null
            ? const VolumeAvailability.unknown()
            : VolumeAvailability.known(freeBytes),
      },
      volumeForDatabase: const VolumeId('internal'),
    );
    return SpaceEstimateSnapshot.of(plan);
  }

  ReceiveConfirmationPage pageWith(SpaceEstimateSnapshot? estimate) =>
      ReceiveConfirmationPage(
        fileCount: 1,
        totalBytes: 4 * 1024 * 1024,
        estimate: estimate,
        saveLocationLabel: '内部存储',
      );

  Widget host(ReceiveConfirmationPage page) =>
      MaterialApp(theme: buildNearSendTheme(Brightness.light), home: page);

  testWidgets('a sufficient volume states the margin is not a guarantee', (
    tester,
  ) async {
    final ReceiveConfirmationPage page = pageWith(
      snapshotFor(freeBytes: 1 << 40),
    );
    await tester.pumpWidget(host(page));

    expect(page.verdict, SpaceVerdict.sufficient);
    expect(page.isBlocked, isFalse);
    expect(page.needsRiskAcknowledgement, isFalse);
    expect(
      page.spaceStatusLabel,
      contains('不是保证'),
      reason:
          '§16.2 makes the margin a policy, so a pass must not read as a guarantee that the '
          'space is enough',
    );
    expect(find.text(page.spaceStatusLabel), findsOneWidget);
  });

  testWidgets('a known shortfall blocks acceptance and names the gap', (
    tester,
  ) async {
    final ReceiveConfirmationPage page = pageWith(snapshotFor(freeBytes: 4096));
    await tester.pumpWidget(host(page));

    expect(page.verdict, SpaceVerdict.insufficient);
    expect(
      page.isBlocked,
      isTrue,
      reason:
          '§11 pairs SPACE_INSUFFICIENT with freeing space or changing location; starting a '
          'transfer that cannot finish costs the bytes already moved',
    );
    expect(page.needsRiskAcknowledgement, isFalse);
    expect(find.textContaining('空间不足'), findsWidgets);
    expect(
      find.textContaining('还差'),
      findsWidgets,
      reason: 'the shortfall is part of the breakdown §16.2 requires, not a bare refusal',
    );
  });

  testWidgets('an unverifiable volume is not a pass and asks for the risk', (
    tester,
  ) async {
    final ReceiveConfirmationPage page = pageWith(snapshotFor(freeBytes: null));
    await tester.pumpWidget(host(page));

    expect(page.verdict, SpaceVerdict.unknown);
    expect(
      page.spaceStatusLabel,
      isNot(contains('空间检查通过')),
      reason:
          '§16.1 forbids showing an unknown reading as a passed check - the most important '
          'negative assertion on this screen',
    );
    expect(
      page.needsRiskAcknowledgement,
      isTrue,
      reason: 'unknown is confirmable rather than refused, so it must be asked about',
    );
    expect(page.isBlocked, isFalse);
  });

  testWidgets('no estimate at all says so rather than implying a pass', (
    tester,
  ) async {
    final ReceiveConfirmationPage page = pageWith(null);
    await tester.pumpWidget(host(page));

    expect(page.verdict, isNull);
    expect(page.spaceStatusLabel, '未做空间检查');
    expect(page.spaceStatusLabel, isNot(contains('通过')));
  });

  testWidgets('the planner own explanations are rendered per volume', (
    tester,
  ) async {
    final SpaceEstimateSnapshot estimate = snapshotFor(freeBytes: 1 << 40);
    await tester.pumpWidget(host(pageWith(estimate)));

    // §16.2: "空间计划输出每个卷的解释性明细……不能只返回布尔值". The lines are rendered rather than
    // folded into a total the user cannot decompose.
    expect(estimate.volumes, isNotEmpty);
    for (final SpaceVolumeSnapshot volume in estimate.volumes) {
      expect(volume.lines, isNotEmpty);
      expect(find.text(volume.volumeRef), findsOneWidget);
    }
  });
}
