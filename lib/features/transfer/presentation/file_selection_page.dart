import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/protocol/relative_path.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';

/// One file the user picked, as this screen needs to describe it.
///
/// Deliberately not `OutgoingFileChoice`: that type carries the local path, which a screen must not
/// render (`AGENTS.md` §5 keeps user file locations out of diagnostics) and a widget test cannot
/// check. What a person needs to see is the name and the size, and what the manifest needs is the
/// identifier.
class SelectedFile {
  const SelectedFile({
    required this.fileId,
    required this.relativePath,
    required this.sizeBytes,
  });

  final String fileId;

  /// The manifest name, already normalised by the sender.
  final String relativePath;

  final int sizeBytes;

  /// The name a person reads, which is the last path segment.
  String get displayName {
    final int slash = relativePath.lastIndexOf('/');
    return slash < 0 ? relativePath : relativePath.substring(slash + 1);
  }
}

/// What the selection screen decided about a set of files.
///
/// Separate from the widget so the rules can be stated once and asserted directly: a screen that
/// decided these inline would have its rules tested only through rendered text.
class FileSelectionReport {
  const FileSelectionReport({
    required this.files,
    required this.problems,
    required this.totalBytes,
  });

  final List<SelectedFile> files;

  /// Every reason this selection cannot be sent, each already a sentence a user can act on.
  ///
  /// Empty means the selection is sendable. It is a list rather than a first-failure because
  /// telling somebody about one problem at a time, when they picked ten files, makes them repeat
  /// the whole flow.
  final List<String> problems;

  final int totalBytes;

  bool get canSend => problems.isEmpty && files.isNotEmpty;

  /// Duplicate display names, which §5.1 permits **only** with distinct file ids.
  ///
  /// The protocol allows them and the receiver renames; the screen still says so, because a user
  /// who picked the same name twice usually meant to pick one file and will otherwise be surprised
  /// by a `(1)` copy on the other side.
  List<String> get duplicateNames {
    final Map<String, int> counts = <String, int>{};
    for (final SelectedFile file in files) {
      counts[file.displayName] = (counts[file.displayName] ?? 0) + 1;
    }
    return <String>[
      for (final MapEntry<String, int> entry in counts.entries)
        if (entry.value > 1) entry.key,
    ]..sort();
  }

  /// Checks a selection against §5's limits, without consulting the network or the disk.
  static FileSelectionReport of(List<SelectedFile> files) {
    final List<String> problems = <String>[];
    int total = 0;
    int chunks = 0;
    final Set<String> seenIds = <String>{};

    for (final SelectedFile file in files) {
      if (!seenIds.add(file.fileId)) {
        problems.add('文件标识重复：${file.displayName}');
      }
      // §5.1's path rules, applied here so a name that would be refused on the wire is refused
      // before the user waits for a manifest upload to fail.
      try {
        RelativePathRules.validate(file.relativePath);
      } on Object {
        problems.add('文件名不符合协议要求：${file.displayName}');
      }
      total += file.sizeBytes;
      chunks += chunkCountForSize(
        file.sizeBytes,
        ProtocolLimits.chunkSizeBytes,
      );
    }

    if (files.isEmpty) {
      problems.add('还没有选择任何文件');
    }
    if (files.length > ProtocolLimits.maxFilesPerTransfer) {
      problems.add('文件数超过上限（${ProtocolLimits.maxFilesPerTransfer}）');
    }
    if (chunks > ProtocolLimits.maxChunksPerTransfer) {
      problems.add(
        '分块总数超过上限（${ProtocolLimits.maxChunksPerTransfer}），请减少文件或缩小范围',
      );
    }
    if (total > ProtocolLimits.maxDecimalValue) {
      // §4: the summed size must not overflow signed 64-bit. Reported rather than truncated.
      problems.add('总大小超出协议可表示范围');
    }

    return FileSelectionReport(
      files: List<SelectedFile>.unmodifiable(files),
      problems: List<String>.unmodifiable(problems),
      totalBytes: total,
    );
  }
}

/// The selection result: what was picked, how much it is, and whether it can be sent.
///
/// `docs/ui/UI_UX_SPEC.md` §5 asks for this step to exist so the user sees the consequence of their
/// choice before anything is offered, and `技术方案 V2.1` §16.1 asks for the preparation step to be
/// visible. The screen therefore reports the total and the **reason** when a selection cannot be
/// sent, rather than only disabling the button - a disabled button with no explanation is the
/// failure mode this screen exists to avoid.
class FileSelectionPage extends StatelessWidget {
  const FileSelectionPage({
    super.key,
    required this.report,
    this.onSend,
    this.onAddFiles,
  });

  final FileSelectionReport report;

  final VoidCallback? onSend;
  final VoidCallback? onAddFiles;

  /// The heading count and size, in the same units as the per-file rows.
  String get summaryLabel =>
      '${report.files.length} 个文件 · ${formatBytes(report.totalBytes)}';

  @override
  Widget build(BuildContext context) {
    final NearSendColors palette = NearSendColors.of(
      Theme.of(context).brightness,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('已选择的文件')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: NearSendSizing.formMaxWidth,
            ),
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.all(NearSendSpacing.lg),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      summaryLabel,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
                if (report.duplicateNames.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NearSendSpacing.lg,
                    ),
                    child: _Notice(
                      palette: palette,
                      text:
                          '有重名文件（${report.duplicateNames.join('、')}）：'
                          '协议允许发送，接收端会自动改名以免覆盖。',
                    ),
                  ),
                for (final String problem in report.problems)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NearSendSpacing.lg,
                      vertical: NearSendSpacing.xxs,
                    ),
                    child: _Notice(
                      palette: palette,
                      text: problem,
                      isError: true,
                    ),
                  ),
                const SizedBox(height: NearSendSpacing.sm),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NearSendSpacing.lg,
                    ),
                    itemCount: report.files.length,
                    itemBuilder: (BuildContext context, int index) {
                      final SelectedFile file = report.files[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.insert_drive_file_outlined),
                        title: Text(file.displayName),
                        // Only when it says something the title does not: for a flat name the two
                        // are identical, and repeating it is noise the user has to read twice.
                        subtitle: file.relativePath == file.displayName
                            ? null
                            : Text(file.relativePath),
                        trailing: Text(formatBytes(file.sizeBytes)),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(NearSendSpacing.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      FilledButton.icon(
                        // Disabled rather than absent: the user can still fix the selection, so
                        // the control stays visible with the reasons listed above it.
                        onPressed: report.canSend ? onSend : null,
                        icon: const Icon(Icons.send_outlined),
                        label: const Text('发送'),
                      ),
                      const SizedBox(height: NearSendSpacing.sm),
                      OutlinedButton.icon(
                        onPressed: onAddFiles,
                        icon: const Icon(Icons.add),
                        label: const Text('继续添加'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.palette,
    required this.text,
    this.isError = false,
  });

  final NearSendColors palette;
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(NearSendSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              isError ? Icons.error_outline : Icons.info_outline,
              color: isError ? palette.error : palette.primary,
            ),
            const SizedBox(width: NearSendSpacing.sm),
            Expanded(
              child: Text(text, style: Theme.of(context).textTheme.bodySmall),
            ),
          ],
        ),
      ),
    );
  }
}
