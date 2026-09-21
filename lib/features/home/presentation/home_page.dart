import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';

/// NearSend home shell.
///
/// Scope is the information architecture of `docs/ui/UI_UX_SPEC.md` §4 "首页":
///
/// * 发送文件 / 接收文件 as the two primary actions with equal visual weight;
/// * 继续任务 only when recoverable tasks exist — none exist yet, so it is not
///   rendered at all rather than rendered empty;
/// * the empty-state sentence explaining that no internet is needed but a
///   local Wi-Fi link is.
///
/// ## The actions now do something, and the note says how much
///
/// They were disabled shells while no transport existed. Both are now wired to real routes: the
/// send action opens the connection screen, which publishes this device's real pairing payload
/// and accepts one that the user pastes, and the receive action opens the same screen with the
/// receive wording. So the buttons are no longer a placeholder.
///
/// The note underneath is **not** removed, because the flows below this screen are not finished:
/// choosing files still needs the platform picker, and the transfer screen has no engine behind it
/// yet on a device. A reviewer must not read an enabled button as "file transfer works", and
/// `docs/AGENT_TASK_PLAYBOOK.md` §9 forbids presenting a partial capability as a finished one. So
/// the note stays and says precisely what is still missing.
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  static const String connectRoute = '/connect';
  static const String transferRoute = '/transfer';

  /// Shown under each action. States the remaining gap rather than "not implemented", which is
  /// no longer true of the button itself.
  ///
  /// The middle sentence is the one that matters: a transfer between two installations works when
  /// **both** devices have pasted the other's connection information, because then each is a client
  /// of the other and the sending side offers the file for the other to pull. With only one paste,
  /// only the pasted-into device can send (the other direction would need a server-side acceptance
  /// this build does not have yet). A note that said only 已接通 would be read as "随便哪一端都能发".
  static const String remainingWorkNote =
      '两端需要互相粘贴对方的连接信息才能互传；续传、Windows 取件器与真机双向验证仍未完成。';

  static const String emptyStateExplanation = '无需互联网，设备之间仍需建立本地 Wi-Fi 连接。';

  static const String baselineNotice =
      '当前仍为工程壳：协议、配对、存储与双向数据面已有实现和测试，“发送”与“接收”两条界面路径已接通，'
      '两台设备互相粘贴连接信息后即可经真实 TLS 互传并各自校验落盘。尚未完成：断点续传、'
      'Windows 取件器、以及只粘贴一侧时的推送受理（需本机作为服务端受理，未做）。';

  @override
  Widget build(BuildContext context) {
    final NearSendColors palette = NearSendColors.of(
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
                _PrimaryAction(
                  icon: Icons.upload_file_outlined,
                  label: '发送文件',
                  onPressed: () =>
                      Navigator.of(context)
                          .pushNamed(connectRoute, arguments: 'send'),
                ),
                const SizedBox(height: NearSendSpacing.sm),
                _PrimaryAction(
                  icon: Icons.download_outlined,
                  label: '接收文件',
                  onPressed: () =>
                      Navigator.of(context)
                          .pushNamed(connectRoute, arguments: 'receive'),
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

  final NearSendColors palette;

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

/// A primary action with an explicit note about what still lies below it.
///
/// The enabled state and the note are deliberately kept together: a button that works is not the
/// same claim as a flow that works, and separating them is how the second gets implied by the
/// first.
class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FilledButton.icon(
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label),
        ),
        Padding(
          padding: const EdgeInsets.only(top: NearSendSpacing.xxs),
          child: Text(
            HomePage.remainingWorkNote,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
