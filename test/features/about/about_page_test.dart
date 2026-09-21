import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/build_info/build_info.dart';
import 'package:nearsend/features/about/presentation/about_page.dart';

/// T01-01 acceptance: the application must display the version, Git commit,
/// protocol version and database schema version — and must label the draft
/// protocol and the not-yet-integrated storage runtime honestly.
void main() {
  Future<void> pumpAboutPage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: AboutPage()));
  }

  testWidgets('shows the application version', (tester) async {
    await pumpAboutPage(tester);

    expect(find.text(AboutPage.title), findsOneWidget);
    expect(find.text(kAppName), findsOneWidget);
    expect(find.text('$kAppVersion+$kAppBuildNumber'), findsOneWidget);
    expect(find.text('应用版本'), findsOneWidget);
  });

  testWidgets('shows the Git commit honestly', (tester) async {
    await pumpAboutPage(tester);

    expect(find.text('Git 提交'), findsOneWidget);
    expect(find.text(gitShaDisplay), findsOneWidget);

    if (!isGitShaInjected) {
      // A development run without --dart-define must never show a made-up SHA.
      expect(find.textContaining('unknown'), findsWidgets);
    }
  });

  testWidgets('shows the protocol version and marks it as an unfrozen draft', (
    tester,
  ) async {
    await pumpAboutPage(tester);

    expect(find.text('协议版本'), findsOneWidget);
    expect(
      find.text('$protocolVersionDisplay · $protocolStatusDisplay'),
      findsOneWidget,
    );
    expect(find.textContaining('未冻结'), findsWidgets);
  });

  testWidgets(
    'shows the schema version and distinguishes implementation from integration',
    (tester) async {
      await pumpAboutPage(tester);

      expect(find.text('数据库 schema 版本'), findsOneWidget);
      expect(find.text(dbSchemaDisplay), findsOneWidget);
      expect(find.textContaining('存储层已实现'), findsWidgets);
      expect(find.textContaining('应用尚未装配'), findsWidgets);
      expect(find.textContaining('数据库尚未创建'), findsNothing);
    },
  );

  testWidgets('shows the build channel', (tester) async {
    await pumpAboutPage(tester);

    expect(find.text('构建渠道'), findsOneWidget);
    expect(find.text(buildChannelDisplay), findsOneWidget);
  });
}
