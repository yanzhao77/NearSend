import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/features/home/presentation/home_page.dart';

/// T01-01 shell behaviour.
///
/// The home shell must expose the two primary actions with equal weight and
/// must not present them as working functionality. See
/// `docs/AGENT_TASK_PLAYBOOK.md` §9.
void main() {
  Future<void> pumpHomePage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
  }

  testWidgets('renders both primary actions', (tester) async {
    await pumpHomePage(tester);

    expect(find.text('发送文件'), findsOneWidget);
    expect(find.text('接收文件'), findsOneWidget);
    expect(find.byType(FilledButton), findsNWidgets(2));
  });

  testWidgets('primary actions are disabled and labelled as not implemented', (
    tester,
  ) async {
    await pumpHomePage(tester);

    for (final FilledButton button in tester.widgetList<FilledButton>(
      find.byType(FilledButton),
    )) {
      expect(
        button.onPressed,
        isNotNull,
        reason:
            'both actions are now wired to the real connection screen; the note below them '
            'states what is still missing rather than the button pretending to work',
      );
    }

    expect(find.text(HomePage.remainingWorkNote), findsNWidgets(2));
  });

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
