import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/app/widgets/near_send_widgets.dart';

/// T12-10's executable UI acceptance checks that do not require a real platform device.
///
/// These cases deliberately use a narrow viewport and 200% text. A component that only works at
/// the default test size is not responsive evidence, and a status that only has a colour is not
/// accessible evidence.
void main() {
  Widget host(Widget child) => MaterialApp(
    theme: buildNearSendTheme(Brightness.light),
    home: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2)),
      child: SizedBox(width: 320, child: child),
    ),
  );

  testWidgets(
    'long file names and errors remain usable at 200% in a narrow view',
    (tester) async {
      await tester.pumpWidget(
        host(
          const SingleChildScrollView(
            child: Column(
              children: <Widget>[
                NsFileRow(
                  fileName:
                      'an-extremely-long-project-export-name-that-keeps-the-extension.tar.gz',
                  sizeLabel: '20.0 GiB',
                  statusLabel: '完整性校验失败，需要更换位置后重试',
                  statusTone: NsStatusTone.error,
                ),
                NsInfoBanner(
                  title: '保存失败',
                  message: '文件已经通过校验，但目标位置拒绝写入。已保存的文件不会被清理。',
                  tone: NsStatusTone.error,
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('完整性校验失败，需要更换位置后重试'), findsWidgets);
      expect(find.text('保存失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'semantic labels expose status and stage without relying on colour',
    (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      addTearDown(semantics.dispose);
      await tester.pumpWidget(
        host(
          const Column(
            children: <Widget>[
              NsStatusBadge(label: '空间未知', tone: NsStatusTone.warning),
              NsStageProgress(
                stages: <String>['准备', '连接', '传输', '校验', '保存'],
                activeIndex: 3,
              ),
            ],
          ),
        ),
      );

      expect(find.bySemanticsLabel('空间未知'), findsOneWidget);
      expect(find.bySemanticsLabel('传输阶段：校验'), findsOneWidget);
    },
  );
}
