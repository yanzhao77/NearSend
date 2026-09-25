import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearsend/features/transfer/presentation/transfer_overview_page.dart';

void main() {
  for (final action in ['发送', '接收']) {
    testWidgets('$action uses the original connection intent', (tester) async {
      Object? intent;
      await tester.pumpWidget(
        MaterialApp(
          home: const TransferOverviewPage(),
          routes: {
            '/connect': (context) {
              intent = ModalRoute.of(context)!.settings.arguments;
              return const Scaffold(body: Text('connection'));
            },
          },
        ),
      );
      await tester.tap(find.widgetWithText(FilledButton, action));
      await tester.pumpAndSettle();
      expect(intent, action == '发送' ? 'send' : 'receive');
    });
  }
}
