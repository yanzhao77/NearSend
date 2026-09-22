import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/app/widgets/near_send_widgets.dart';

void main() {
  Widget host(Widget child, {Brightness brightness = Brightness.light}) =>
      MaterialApp(
        theme: buildNearSendTheme(brightness),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  testWidgets('primary button keeps a stable label while loading', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(const NsPrimaryButton(label: '发送', onPressed: null, loading: true)),
    );
    expect(find.text('处理中…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('banner expresses warning with icon, text and action', (
    tester,
  ) async {
    bool acted = false;
    await tester.pumpWidget(
      host(
        NsInfoBanner(
          title: '空间未知',
          message: '无法确认此位置的可用空间。',
          tone: NsStatusTone.warning,
          actionLabel: '更换位置',
          onAction: () => acted = true,
        ),
      ),
    );
    expect(find.text('空间未知'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
    await tester.tap(find.text('更换位置'));
    expect(acted, isTrue);
  });

  testWidgets('file row truncates long names and shows semantic status', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const NsFileRow(
          fileName: 'a-very-long-file-name-that-keeps-its-extension.tar.gz',
          sizeLabel: '4.0 MiB',
          statusLabel: '传输中',
          statusTone: NsStatusTone.active,
          progress: 0.5,
        ),
      ),
    );
    expect(find.text('传输中'), findsNWidgets(2));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      tester.widget<Tooltip>(find.byType(Tooltip).first).message,
      'a-very-long-file-name-that-keeps-its-extension.tar.gz',
      reason:
          'the visible text is allowed to ellipsize; Tooltip owns the full name',
    );
  });

  testWidgets('stage progress distinguishes complete, active and pending', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const NsStageProgress(
          stages: <String>['准备', '连接', '传输', '校验', '保存'],
          activeIndex: 2,
        ),
      ),
    );
    expect(find.text('准备'), findsOneWidget);
    expect(find.text('传输'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsNWidgets(2));
  });

  testWidgets('unknown space is not rendered as success', (tester) async {
    await tester.pumpWidget(
      host(
        const NsSpaceBreakdown(
          title: '保存卷',
          status: NsSpaceStatus.unknown,
          statusLabel: '无法确认',
          lines: <NsSpaceLine>[NsSpaceLine(label: '需要', value: '4 GiB')],
        ),
      ),
    );
    expect(find.text('无法确认'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_outlined), findsNWidgets(2));
    expect(find.byIcon(Icons.check_circle_outline), findsNothing);
  });

  testWidgets('components remain readable in dark theme at large text scale', (
    tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: host(
          const NsTaskCard(
            title: 'Project Files',
            subtitle: 'Windows-PC · 12 个文件',
            status: NsTaskStatus.recoverable,
            statusLabel: '可恢复',
            progress: 0.64,
            progressLabel: '12.8 / 20.0 GiB',
          ),
          brightness: Brightness.dark,
        ),
      ),
    );
    expect(find.text('Project Files'), findsOneWidget);
    expect(find.text('可恢复'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
