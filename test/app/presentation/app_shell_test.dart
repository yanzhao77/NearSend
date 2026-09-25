import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/application/settings_controller.dart';
import 'package:nearsend/app/application/space_overview_controller.dart';
import 'package:nearsend/app/application/task_catalog_controller.dart';
import 'package:nearsend/app/presentation/app_shell.dart';
import 'package:nearsend/app/theme/design_tokens.dart';

void main() {
  Widget shell() => MaterialApp(
    theme: buildNearSendTheme(Brightness.light),
    home: NearSendAppShell(
      tasks: TaskCatalogController(),
      space: SpaceOverviewController(),
      settings: SettingsController(),
    ),
  );

  testWidgets('mobile navigation moves send and receive into transfer tab', (
    tester,
  ) async {
    await tester.pumpWidget(shell());
    expect(find.text('发送文件'), findsNothing);
    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(nav.destinations, hasLength(5));
    await tester.tap(find.text('传输'));
    await tester.pumpAndSettle();
    expect(find.text('发送文件'), findsOneWidget);
    expect(find.text('接收文件'), findsOneWidget);
    await tester.tap(find.text('首页'));
    await tester.pumpAndSettle();
    expect(find.text('已配对设备'), findsOneWidget);
    expect(find.text('发送文件'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('desktop shell uses the full navigation rail above 900px', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(shell());

    final NavigationRail rail = tester.widget<NavigationRail>(
      find.byType(NavigationRail),
    );
    expect(rail.extended, isTrue);
    expect(rail.destinations, hasLength(5));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('compact desktop shell keeps the 72px icon rail', (tester) async {
    await tester.binding.setSurfaceSize(const Size(899, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(shell());

    final NavigationRail rail = tester.widget<NavigationRail>(
      find.byType(NavigationRail),
    );
    expect(rail.extended, isFalse);
    expect(rail.minWidth, NearSendSizing.desktopSidebarCollapsedWidth);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('desktop content is in a focus traversal group', (tester) async {
    await tester.pumpWidget(shell());

    expect(
      find.descendant(
        of: find.byType(NearSendAppShell),
        matching: find.byType(FocusTraversalGroup),
      ),
      findsOneWidget,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
