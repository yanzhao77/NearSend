import 'package:nearsend/core/security/pairing_service.dart';
import 'package:nearsend/core/storage/source_bytes.dart';
import 'package:nearsend/core/transfer/transfer_engine.dart';
import 'package:nearsend/features/transfer/presentation/file_selection_page.dart';
import 'package:nearsend/platform/android_file_gateway.dart';

/// Turns picked SAF documents into a selection the screen can report on.
///
/// This is the join `AGENTS.md` §4 asks for: `lib/platform/` speaks the channel's language and
/// `features/` decides what a selection means, so neither has to know the other's rules.
///
/// ## The case that shapes this class
///
/// A SAF provider may refuse to report a document's size, and `AGENTS.md` §2 rule 4 forbids finding
/// out by reading the whole file. So the size is genuinely unknown at this point, and the class does
/// **not** invent one:
///
/// * it does not become `0`, because §5.2 hashes the real size into the manifest and a zero would
///   describe a different file;
/// * it does not refuse the whole selection, because one provider being quiet about one document
///   says nothing about the others;
/// * the document is **left out of the report with a reason**, so the total the user is shown is a
///   total of files whose size is actually known.
///
/// The real size is discovered by the sender's planner, which has to read the file anyway to compute
/// §5.2's and §5.3's digests. So the honest sequence is: pick, report what is known, and let planning
/// supply the rest - which is why this class stops where it does rather than guessing.
class FileSelectionController {
  FileSelectionController({required this.gateway, this.idFactory});

  final AndroidFileGateway gateway;

  /// Supplies a canonical UUID per file. Injected so a test can state the identifiers rather than
  /// matching random ones, and because §4 makes identifier generation a protocol concern rather
  /// than a platform one.
  final String Function()? idFactory;

  /// Opens the picker and reports on what came back.
  ///
  /// An empty selection produces the report's own "nothing chosen yet" problem rather than a
  /// failure: cancelling the picker is not an error.
  Future<FileSelectionReport> pick() async {
    final List<PickedDocument> documents = await gateway.pickFiles();
    return report(documents);
  }

  /// Reports on [documents] without opening the picker.
  FileSelectionReport report(
    List<PickedDocument> documents, {
    Set<String> alreadyChosen = const <String>{},
  }) {
    final List<SelectedFile> files = <SelectedFile>[];
    final List<String> withheld = <String>[];

    for (final PickedDocument document in documents) {
      if (alreadyChosen.contains(document.uri)) {
        // Adding the same document twice would be two manifest entries for one user file, and the
        // receiver would write it out twice. Skipped rather than reported as a problem, because it
        // is the normal result of choosing "add more" and picking the same file again by mistake.
        continue;
      }
      final int? size = document.sizeBytes;
      if (size == null) {
        withheld.add(document.displayName);
        continue;
      }
      files.add(
        SelectedFile(
          fileId: (idFactory ?? _defaultIdFactory)(),
          // Kept so the selection can become sending choices: a report that knew only names and
          // sizes could describe a transfer but not start one.
          sourceRef: document.uri,
          // §5.1 wants NFC and a POSIX-relative path; a provider's display name is neither
          // guaranteed, so the report's own validation is what decides whether it is usable.
          relativePath: document.displayName,
          sizeBytes: size,
        ),
      );
    }

    final FileSelectionReport base = FileSelectionReport.of(files);
    if (withheld.isEmpty) {
      return base;
    }
    return FileSelectionReport(
      files: base.files,
      totalBytes: base.totalBytes,
      problems: <String>[
        ...base.problems,
        // Said as its own line rather than folded into a total, because a total that quietly
        // omitted these files would understate the transfer and a total that guessed would
        // overstate it.
        '以下文件无法读取大小，将在开始传输时确定：${withheld.join('、')}',
      ],
    );
  }

  static String _defaultIdFactory() => randomUuidV4();

  /// Turns a selection into the choices a sending transfer is planned from.
  ///
  /// This is the join the screen was missing: [FileSelectionReport] knew each file's name and size
  /// but not where its bytes were, so nothing could be proposed from it. The bytes come from the
  /// gateway by the document URI the picker returned, which is why that reference had to be kept.
  ///
  /// Refuses rather than guessing when a file has no reference: a choice built without one would
  /// fail later inside planning with a message about hashing, which says nothing about the real
  /// problem.
  List<OutgoingFileChoice> choicesFor(FileSelectionReport report) {
    return <OutgoingFileChoice>[
      for (final SelectedFile file in report.files)
        OutgoingFileChoice(
          fileId: file.fileId,
          relativePath: file.relativePath,
          source: SafSourceBytes(
            gateway: gateway,
            uri:
                file.sourceRef ??
                (throw StateError(
                  '${file.displayName} has no source reference, so its bytes cannot be read',
                )),
            providerReportedSize: file.sizeBytes,
          ),
        ),
    ];
  }
}
