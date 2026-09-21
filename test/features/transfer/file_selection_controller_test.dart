import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/features/transfer/application/file_selection_controller.dart';
import 'package:nearsend/features/transfer/presentation/file_selection_page.dart';
import 'package:nearsend/platform/android_file_gateway.dart';

/// The join between the SAF channel and the selection screen.
///
/// The case worth the most here is the provider that will not report a size, because every
/// convenient answer is wrong: guessing zero builds a manifest for a different file, refusing the
/// whole selection punishes the other documents for one provider's silence, and reading the file to
/// find out is the buffering `AGENTS.md` §2 rule 4 forbids.
void main() {
  PickedDocument document(String name, int? size, {String? uri}) =>
      PickedDocument(
        uri: uri ?? 'content://provider/$name',
        displayName: name,
        sizeBytes: size,
      );

  FileSelectionController controller({
    List<PickedDocument>? picks,
    List<String>? ids,
  }) {
    int next = 0;
    return FileSelectionController(
      gateway: InMemoryFileGateway()
        ..nextPick = picks ?? const <PickedDocument>[],
      idFactory: ids == null
          ? null
          : () => ids[next < ids.length ? next++ : ids.length - 1],
    );
  }

  test('a normal pick becomes a sendable report', () async {
    final FileSelectionController subject = controller(
      picks: <PickedDocument>[document('a.bin', 1024), document('b.bin', 2048)],
    );

    final FileSelectionReport report = await subject.pick();
    expect(report.canSend, isTrue);
    expect(report.files, hasLength(2));
    expect(report.totalBytes, 3072);
  });

  test('a cancelled pick is an empty report, not a failure', () async {
    final FileSelectionReport report = await controller().pick();
    expect(report.files, isEmpty);
    expect(report.canSend, isFalse);
    expect(report.problems, contains('还没有选择任何文件'));
  });

  test('a withheld size is left out and said so, never guessed', () {
    final FileSelectionController subject = controller(
      ids: <String>['11111111-2222-4333-8444-555555555555'],
    );

    final FileSelectionReport report = subject.report(<PickedDocument>[
      document('known.bin', 4096),
      document('quiet.bin', null),
    ]);

    expect(
      report.files.map((SelectedFile f) => f.displayName),
      <String>['known.bin'],
      reason:
          'the file whose size nobody knows cannot be part of a total, and §5.2 would hash a '
          'guessed size into the manifest',
    );
    expect(
      report.totalBytes,
      4096,
      reason: 'the total covers only what is actually known',
    );
    expect(
      report.problems.join(),
      contains('quiet.bin'),
      reason: 'the user is told which file is waiting on size discovery, not left wondering',
    );
  });

  test('a document already chosen is skipped rather than duplicated', () {
    final FileSelectionController subject = controller(
      ids: <String>['11111111-2222-4333-8444-555555555555'],
    );
    final PickedDocument again = document('a.bin', 10);

    final FileSelectionReport report = subject.report(
      <PickedDocument>[again],
      alreadyChosen: <String>{again.uri},
    );

    expect(
      report.files,
      isEmpty,
      reason:
          'two manifest entries for one user file would make the receiver write it out twice, '
          'and picking the same file again after "add more" is a normal mistake',
    );
    expect(report.problems, contains('还没有选择任何文件'));
  });

  test('every picked document gets its own identifier', () {
    int issued = 0;
    final FileSelectionController subject = FileSelectionController(
      gateway: InMemoryFileGateway(),
      idFactory: () {
        final String id =
            '00000000-0000-4000-8000-${issued.toString().padLeft(12, "0")}';
        issued++;
        return id;
      },
    );

    final FileSelectionReport report = subject.report(<PickedDocument>[
      document('a.bin', 1),
      document('b.bin', 1),
    ]);

    final Set<String> ids = report.files
        .map((SelectedFile f) => f.fileId)
        .toSet();
    expect(
      ids,
      hasLength(2),
      reason:
          '§5 forbids a repeated fileId, and the manifest digest depends on it',
    );
  });
}
