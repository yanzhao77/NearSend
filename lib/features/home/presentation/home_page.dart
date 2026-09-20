import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';

/// NearSend home shell.
///
/// Scope for T01-01 is deliberately limited to the information architecture of
/// `docs/ui/UI_UX_SPEC.md` §4 "首页":
///
/// * 发送文件 / 接收文件 as the two primary actions with equal visual weight;
/// * 继续任务 only when recoverable tasks exist — none exist yet, so it is not
///   rendered at all rather than rendered empty;
/// * the empty-state sentence explaining that no internet is needed but a
///   local Wi-Fi link is.
///
/// The primary actions are **disabled on purpose**. Transport, pairing and
/// discovery are not implemented yet, and `docs/AGENT_TASK_PLAYBOOK.md` §9
/// forbids presenting a static shell as a finished capability.
///
/// Two things UI_UX_SPEC §4 asks for are *not* shown because their real data
/// source does not exist yet: the local device name and the current network
/// availability. Faking either would be a false claim, so the page instead
/// states plainly what is not implemented.
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  static const String notImplementedNote = '功能尚未实现（T03-01 / T03-02）';

  static const String emptyStateExplanation = '无需互联网，设备之间仍需建立本地 Wi-Fi 连接。';

  static const String baselineNotice =
      '当前为 T01-01 工程基线：发送、接收、配对、发现、存储与导出功能均未实现。';

  @override
  Widget build(BuildContext context) {
    final NearSendPalette palette = NearSendPalette.of(
      Theme.of(context).brightness,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('NearSend'),
        actions: <Widget>[
          IconButton(
            onPressed: () => Navigator.of(context).pushNamed('/about'),
            tooltip: '版本与诊断信息',
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: NearSendSizing.formMaxWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.all(NearSendSpacing.lg),
              children: <Widget>[
                _BaselineNotice(palette: palette),
                const SizedBox(height: NearSendSpacing.lg),
                Text(
                  emptyStateExplanation,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: NearSendSpacing.xl),
                const _PrimaryAction(
                  icon: Icons.upload_file_outlined,
                  label: '发送文件',
                ),
                const SizedBox(height: NearSendSpacing.sm),
                const _PrimaryAction(
                  icon: Icons.download_outlined,
                  label: '接收文件',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BaselineNotice extends StatelessWidget {
  const _BaselineNotice({required this.palette});

  final NearSendPalette palette;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(NearSendSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.construction_outlined, color: palette.warning),
            const SizedBox(width: NearSendSpacing.sm),
            Expanded(
              child: Text(
                HomePage.baselineNotice,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A disabled primary action with an explicit "not implemented" note.
///
/// Kept disabled rather than wired to a placeholder route so that no user or
/// reviewer can mistake the shell for working functionality.
class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FilledButton.icon(
          onPressed: null,
          icon: Icon(icon),
          label: Text(label),
        ),
        Padding(
          padding: const EdgeInsets.only(top: NearSendSpacing.xxs),
          child: Text(
            HomePage.notImplementedNote,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
