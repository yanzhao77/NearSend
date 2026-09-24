import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/application/radar_controller.dart';
import 'package:nearsend/features/home/presentation/home_page.dart';

/// T12-04 acceptance for the real home shell.
void main() {
  Future<void> pumpHomePage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
  }

  testWidgets('renders both primary actions', (tester) async {
    await pumpHomePage(tester);

    expect(find.text('发送文件'), findsAtLeastNWidgets(1));
    expect(find.text('接收文件'), findsAtLeastNWidgets(1));
    expect(find.byType(FilledButton), findsNWidgets(2));
  });

  testWidgets(
    'primary actions are enabled and explain the completion boundary',
    (tester) async {
      await pumpHomePage(tester);

      for (final FilledButton button in tester.widgetList<FilledButton>(
        find.byType(FilledButton),
      )) {
        expect(
          button.onPressed,
          isNotNull,
          reason: 'the primary actions open the real connection flow',
        );
      }

      final Finder completionNote = find.text(HomePage.remainingWorkNote);
      await tester.scrollUntilVisible(completionNote, 300);
      expect(completionNote, findsOneWidget);
    },
  );

  testWidgets('explains that no internet is required but a local link is', (
    tester,
  ) async {
    await pumpHomePage(tester);

    expect(find.text(HomePage.emptyStateExplanation), findsOneWidget);
  });

  testWidgets(
    'states plainly that the user-facing transfer flow is not integrated',
    (tester) async {
      await pumpHomePage(tester);

      expect(find.text(HomePage.baselineNotice), findsOneWidget);
    },
  );

  testWidgets(
    'does not render a continue-task action while none is recoverable',
    (tester) async {
      await pumpHomePage(tester);

      expect(find.text('继续任务'), findsNothing);
    },
  );

  testWidgets('radar defaults off and forwards an explicit enable request', (
    tester,
  ) async {
    bool? requested;
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(onRadarReadyChanged: (bool value) => requested = value),
      ),
    );

    await tester.scrollUntilVisible(find.text('附近设备雷达'), 300);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    await tester.tap(find.byType(Switch));
    expect(requested, isTrue);
  });

  testWidgets('only verified ready devices render a green status semantic', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HomePage(
          radarReady: true,
          radarDevices: <RadarDevice>[
            RadarDevice(
              id: 'candidate',
              name: '未经验证的候选设备',
              detail: '蓝牙候选',
              isKnown: false,
              isReady: false,
              isRevoked: false,
            ),
            RadarDevice(
              id: 'verified',
              name: '已验证设备',
              detail: 'Windows',
              isKnown: true,
              isReady: true,
              isRevoked: false,
            ),
          ],
        ),
      ),
    );

    await tester.scrollUntilVisible(find.text('已验证设备'), 300);
    final Text verifiedName = tester.widget<Text>(find.text('已验证设备'));
    expect(verifiedName.semanticsLabel, '已验证设备，已实时验证并就绪');
    expect(find.text('未经验证的候选设备'), findsOneWidget);
    expect(find.byIcon(Icons.devices_outlined), findsOneWidget);
  });

  testWidgets('long peer names fit a narrow viewport', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: HomePage(
          radarDevices: <RadarDevice>[
            RadarDevice(
              id: 'long',
              name: '这是一台名称非常非常长但仍然必须在窄屏中安全换行显示的 Windows 设备',
              detail: '局域网候选 · 2 个地址',
              isKnown: false,
              isReady: false,
              isRevoked: false,
            ),
          ],
        ),
      ),
    );

    await tester.scrollUntilVisible(find.textContaining('这是一台名称'), 300);
    expect(tester.takeException(), isNull);
  });
}
