import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/features/transfer/presentation/file_selection_page.dart';

/// The selection result, and the rules it applies before anything is offered.
///
/// `docs/ui/UI_UX_SPEC.md` §5 puts this step between choosing files and proposing a transfer so the
/// user meets the consequence of their choice first. The rules themselves live in
/// [FileSelectionReport], which is why they can be asserted directly here instead of only through
/// rendered text - the lesson from the previous screen, where label-based assertions were both
/// brittle and weaker than the rule they stood in for.
void main() {
  SelectedFile file(String name, int size, {String? id}) => SelectedFile(
    fileId:
        id ??
        '00000000-0000-4000-8000-${name.hashCode.abs() % 1000000000000}'
            .padRight(36, '0')
            .substring(0, 36),
    relativePath: name,
    sizeBytes: size,
  );

  group('selection rules', () {
    test('an empty selection cannot be sent, and says why', () {
      final FileSelectionReport report = FileSelectionReport.of(
        const <SelectedFile>[],
      );
      expect(report.canSend, isFalse);
      expect(report.problems, contains('还没有选择任何文件'));
    });

    test('a valid selection is sendable and totals its bytes', () {
      final FileSelectionReport report = FileSelectionReport.of(<SelectedFile>[
        file('a.bin', 1024),
        file('b.bin', 2048),
      ]);
      expect(report.canSend, isTrue);
      expect(report.problems, isEmpty);
      expect(report.totalBytes, 3072);
    });

    test('a relative path that violates §5.1 is refused before the wire', () {
      final FileSelectionReport report = FileSelectionReport.of(<SelectedFile>[
        file('../escape.bin', 10),
      ]);
      expect(
        report.canSend,
        isFalse,
        reason:
            'a name the protocol would refuse must be refused here rather than after the '
            'user waits for a manifest upload to fail',
      );
      expect(report.problems, isNotEmpty);
    });

    test(
      'duplicate identifiers are a problem, duplicate names are only a note',
      () {
        final SelectedFile first = file('same.bin', 10, id: 'dup');
        final SelectedFile second = file('same.bin', 20, id: 'dup');
        final FileSelectionReport duplicated = FileSelectionReport.of(
          <SelectedFile>[first, second],
        );
        expect(
          duplicated.canSend,
          isFalse,
          reason: '§5 forbids a repeated fileId, and the manifest digest depends on it',
        );

        final FileSelectionReport sameName = FileSelectionReport.of(
          <SelectedFile>[file('dir/a.bin', 10), file('other/a.bin', 20)],
        );
        expect(
          sameName.canSend,
          isTrue,
          reason:
              '§5.1 allows the same display name when the identifiers differ',
        );
        expect(sameName.duplicateNames, <String>['a.bin']);
      },
    );

    test('too many files is refused with the limit in the message', () {
      final List<SelectedFile> many = <SelectedFile>[
        for (int i = 0; i <= ProtocolLimits.maxFilesPerTransfer; i++)
          file('f$i.bin', 1),
      ];
      final FileSelectionReport report = FileSelectionReport.of(many);
      expect(report.canSend, isFalse);
      expect(
        report.problems.join(),
        contains('${ProtocolLimits.maxFilesPerTransfer}'),
      );
    });

    test('every problem is reported, not only the first', () {
      final FileSelectionReport report = FileSelectionReport.of(<SelectedFile>[
        file('../escape.bin', 10),
        file('ok.bin', 10, id: 'x'),
        file('ok2.bin', 10, id: 'x'),
      ]);
      expect(
        report.problems.length,
        greaterThanOrEqualTo(2),
        reason:
            'telling somebody about one problem at a time, when they picked several files, '
            'makes them repeat the whole flow',
      );
    });
  });

  group('selection screen', () {
    Future<void> pump(
      WidgetTester tester,
      FileSelectionReport report, {
      VoidCallback? onSend,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: buildNearSendTheme(Brightness.light),
        home: FileSelectionPage(report: report, onSend: onSend),
      ),
    );

    testWidgets('lists each file with its size and the total', (tester) async {
      final FileSelectionReport report = FileSelectionReport.of(<SelectedFile>[
        file('报告.bin', 1024),
        file('b.bin', 2048),
      ]);
      await pump(tester, report);

      expect(find.text('报告.bin'), findsOneWidget);
      expect(find.text('1.0 KiB'), findsOneWidget);
      expect(find.text('2.0 KiB'), findsOneWidget);
      expect(find.textContaining('2 个文件'), findsOneWidget);
    });

    testWidgets(
      'the send button is enabled only when the selection is sendable',
      (tester) async {
        bool sent = false;
        final FileSelectionReport bad = FileSelectionReport.of(<SelectedFile>[
          file('../escape.bin', 10),
        ]);
        await pump(tester, bad, onSend: () => sent = true);
        final FilledButton disabled = tester.widget<FilledButton>(
          find.byType(FilledButton),
        );
        expect(disabled.onPressed, isNull);
        expect(
          find.byType(Card),
          findsWidgets,
          reason:
              'the reason is on screen, not only implied by a disabled button',
        );

        final FileSelectionReport good = FileSelectionReport.of(<SelectedFile>[
          file('a.bin', 1024),
        ]);
        await pump(tester, good, onSend: () => sent = true);
        await tester.tap(find.text('发送'));
        expect(sent, isTrue);
      },
    );

    testWidgets('duplicate names are surfaced as a note rather than an error', (
      tester,
    ) async {
      final FileSelectionReport report = FileSelectionReport.of(<SelectedFile>[
        file('dir/a.bin', 10),
        file('other/a.bin', 20),
      ]);
      await pump(tester, report);

      expect(find.textContaining('重名'), findsOneWidget);
      expect(report.canSend, isTrue);
    });
  });
}
