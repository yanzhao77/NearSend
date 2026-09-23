import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
