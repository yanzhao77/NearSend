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
    expect(rail.destinations, hasLength(4));
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
