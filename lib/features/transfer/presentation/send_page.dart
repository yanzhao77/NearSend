import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/features/transfer/application/sending_flow.dart';
import 'package:nearsend/features/transfer/presentation/file_selection_page.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';

/// The sending screen: what is about to go, and how far it has got.
///
/// ## What it will not do
///
/// It renders [SendPhase] rather than deciding anything, and the two controls it may lack are absent
/// rather than disabled: a picker button on a platform with no picker, and a path field on a
/// platform whose files are documents. `AGENTS.md` §9 makes that difference real, so a screen that
/// offered both everywhere would be offering one that cannot work.
///
/// ## Why the wording is a switch and not a string built at the call site
///
/// `preparing` and `waitingForPeer` are the two states where a user is most likely to conclude the
/// application has hung: one is local hashing with no visible network activity, the other is a peer
/// that has not answered yet. They are also entirely different waits, and the only place that knows
/// which is this one.
class SendPage extends StatelessWidget {
  const SendPage({
    super.key,
    required this.report,
    required this.phase,
    this.progress,
    this.fileName,
    this.fileNumber = 0,
    this.fileCount = 0,
    this.failureReason,
    this.onPick,
    this.onAddPath,
    this.onSend,
    this.onClear,
  });

  final FileSelectionReport report;
  final SendPhase phase;

  /// The figures for the file in flight, when one is.
  final TransferProgress? progress;

  final String? fileName;

  /// Which file of the transfer is in flight, one-based.
  final int fileNumber;
  final int fileCount;

  final String? failureReason;

  final VoidCallback? onPick;
  final void Function(String path)? onAddPath;
  final VoidCallback? onSend;
  final VoidCallback? onClear;

  static const String heading = '要发送的文件';
  static const String pickHint = '从本机选择文件';
  static const String pathHint = '输入要发送的文件路径';
  static const String emptyNote = '还没有选择文件。';
  static const String waitingNote = '对方还没有确认这次传输，正在等待。';

  /// Shown while this device is the one offering. The next move is the peer's, and saying so is the
  /// difference between a wait and a hang.
  static const String offeredNote = '文件已提供给对方，正在等对方取走并保存；请让对方在“接收文件”里接受。';

  /// The phase's own words.
  static String phaseLabel(SendPhase phase) => switch (phase) {
    SendPhase.empty => '待选择',
    SendPhase.ready => '可以发送',
    SendPhase.preparing => '正在准备（读取并校验来源）',
    SendPhase.waitingForPeer => '等待对方接受',
    SendPhase.offeredToPeer => '已提供给对方，等待对方取走',
    SendPhase.sending => '传输中',
    SendPhase.awaitingVerification => '已送达，等待对方校验并保存',
    SendPhase.savedByPeer => '对方已保存',
    SendPhase.failed => '未完成',
  };

  /// What the button says, which is not always the phase's name.
  String get actionLabel => switch (phase) {
    SendPhase.preparing => '正在准备…',
    SendPhase.waitingForPeer => '等待对方接受…',
    SendPhase.offeredToPeer => '等待对方取走…',
    SendPhase.sending => '传输中…',
    SendPhase.failed => '重新发送',
    _ => '发送',
  };

  bool get isBusy =>
      phase == SendPhase.preparing ||
      phase == SendPhase.waitingForPeer ||
      phase == SendPhase.offeredToPeer ||
      phase == SendPhase.sending;

  @override
  Widget build(BuildContext context) {
    final NearSendColors palette = NearSendColors.of(
      Theme.of(context).brightness,
    );

    return Scaffold(
      appBar: AppBar(title: const Text(heading)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: NearSendSizing.formMaxWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.all(NearSendSpacing.lg),
              children: <Widget>[
                Text(
                  '${report.files.length} 个文件 · ${formatBytes(report.totalBytes)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: NearSendSpacing.sm),
                if (report.files.isEmpty)
                  Text(
                    emptyNote,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                for (final SelectedFile file in report.files)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    title: Text(file.displayName),
                    subtitle: file.relativePath == file.displayName
                        ? null
                        : Text(file.relativePath),
                    trailing: Text(formatBytes(file.sizeBytes)),
                  ),
                for (final String problem in report.problems)
                  _Notice(palette: palette, text: problem, isError: true),
                const SizedBox(height: NearSendSpacing.md),
                if (onPick != null)
                  FilledButton.tonalIcon(
                    onPressed: isBusy ? null : onPick,
                    icon: const Icon(Icons.folder_open),
                    label: const Text(pickHint),
                  ),
                if (onAddPath != null) ...<Widget>[
                  const SizedBox(height: NearSendSpacing.sm),
                  _PathField(onSubmit: isBusy ? null : onAddPath),
                ],
                const SizedBox(height: NearSendSpacing.lg),
                _PhaseSection(
                  phase: phase,
                  progress: progress,
                  fileName: fileName,
                  fileNumber: fileNumber,
                  fileCount: fileCount,
                  failureReason: failureReason,
                  palette: palette,
                ),
                const SizedBox(height: NearSendSpacing.md),
                FilledButton.icon(
                  onPressed: report.canSend && !isBusy ? onSend : null,
                  icon: const Icon(Icons.send_outlined),
                  label: Text(actionLabel),
                ),
                if (report.files.isNotEmpty) ...<Widget>[
                  const SizedBox(height: NearSendSpacing.sm),
                  OutlinedButton.icon(
                    onPressed: isBusy ? null : onClear,
                    icon: const Icon(Icons.clear_all),
                    label: const Text('清空选择'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The phase, the figures that belong to it, and the reasons it stopped.
class _PhaseSection extends StatelessWidget {
  const _PhaseSection({
    required this.phase,
    required this.progress,
    required this.fileName,
    required this.fileNumber,
    required this.fileCount,
    required this.failureReason,
    required this.palette,
  });

  final SendPhase phase;
  final TransferProgress? progress;
  final String? fileName;
  final int fileNumber;
  final int fileCount;
  final String? failureReason;
  final NearSendColors palette;

  @override
  Widget build(BuildContext context) {
    final TransferProgress? figures = progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          SendPage.phaseLabel(phase),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        if (phase == SendPhase.waitingForPeer)
          Padding(
            padding: const EdgeInsets.only(top: NearSendSpacing.xxs),
            child: Text(
              SendPage.waitingNote,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (phase == SendPhase.offeredToPeer)
          Padding(
            padding: const EdgeInsets.only(top: NearSendSpacing.xxs),
            child: Text(
              SendPage.offeredNote,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (fileCount > 1 && fileNumber > 0)
          Padding(
            padding: const EdgeInsets.only(top: NearSendSpacing.xxs),
            child: Text(
              '第 $fileNumber / $fileCount 个文件',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (figures != null) ...<Widget>[
          const SizedBox(height: NearSendSpacing.sm),
          Text(fileName ?? '', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: NearSendSpacing.xs),
          if (figures.fraction != null)
            LinearProgressIndicator(value: figures.fraction)
          else
            // No total yet: an indeterminate bar is honest, and a determinate one would claim a
            // proportion nobody knows.
            const LinearProgressIndicator(),
          const SizedBox(height: NearSendSpacing.sm),
          _Stat(label: '已传 / 总量', value: figures.byteLabel),
          _Stat(label: '速度', value: figures.speedLabel),
          _Stat(label: '剩余时间', value: figures.remainingLabel),
        ],
        if (failureReason != null)
          Padding(
            padding: const EdgeInsets.only(top: NearSendSpacing.sm),
            child: _Notice(
              palette: palette,
              text: failureReason!,
              isError: true,
            ),
          ),
      ],
    );
  }
}

/// The path entry a platform without a picker uses.
///
/// It keeps its own text so a failed attempt stays visible to be corrected - the reason it failed is
/// shown next to it, which is only useful if the text that produced it is still there.
class _PathField extends StatefulWidget {
  const _PathField({required this.onSubmit});

  final void Function(String path)? onSubmit;

  @override
  State<_PathField> createState() => _PathFieldState();
}

class _PathFieldState extends State<_PathField> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A column rather than a text field beside a button: the field wants all the width it can get
    // for a path, and the button keeps the same full-width shape as the screen's other actions.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          controller: _controller,
          enabled: widget.onSubmit != null,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: SendPage.pathHint,
          ),
        ),
        const SizedBox(height: NearSendSpacing.sm),
        OutlinedButton(
          onPressed: widget.onSubmit == null
              ? null
              : () {
                  final String text = _controller.text.trim();
                  if (text.isNotEmpty) {
                    widget.onSubmit!(text);
                  }
                },
          child: const Text('添加'),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NearSendSpacing.xxs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ],
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
