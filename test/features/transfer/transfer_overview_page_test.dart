import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearsend/features/transfer/presentation/transfer_overview_page.dart';

void main() {
  for (final action in ['发送', '接收']) {
    testWidgets('$action opens its transfer route directly', (tester) async {
      String? route;
      await tester.pumpWidget(
        MaterialApp(
          home: const TransferOverviewPage(),
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) {
              route = settings.name;
              return const Scaffold(body: Text('destination'));
            },
          ),
        ),
      );
      await tester.tap(find.widgetWithText(FilledButton, action));
      await tester.pumpAndSettle();
      expect(route, action == '发送' ? '/send' : '/receive');
    });
  }
}
