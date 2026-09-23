import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/application/settings_controller.dart';
import 'package:nearsend/app/application/space_overview_controller.dart';
import 'package:nearsend/app/application/task_catalog_controller.dart';
import 'package:nearsend/app/presentation/app_shell.dart';
import 'package:nearsend/app/theme/design_tokens.dart';

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  Widget shell() => MaterialApp(
    theme: buildNearSendTheme(Brightness.light),
    home: NearSendAppShell(
      tasks: TaskCatalogController(),
      space: SpaceOverviewController(),
      settings: SettingsController(),
    ),
  );

  testWidgets('desktop shell uses the full navigation rail above 900px', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(shell());

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('任务'), findsOneWidget);
  });

  testWidgets('compact desktop shell keeps the 72px icon rail', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.binding.setSurfaceSize(const Size(899, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(shell());

    final NavigationRail rail = tester.widget<NavigationRail>(
      find.byType(NavigationRail),
    );
    expect(rail.extended, isFalse);
    expect(rail.minWidth, NearSendSizing.desktopSidebarCollapsedWidth);
  });

  testWidgets('desktop content is in a focus traversal group', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.pumpWidget(shell());

    expect(find.byType(FocusTraversalGroup), findsOneWidget);
  });
}
