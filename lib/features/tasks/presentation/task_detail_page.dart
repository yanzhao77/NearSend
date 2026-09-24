import 'package:flutter/material.dart';

import 'package:nearsend/app/application/task_catalog_controller.dart';
import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/app/widgets/near_send_widgets.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';
import 'package:nearsend/features/transfer/presentation/transfer_progress.dart';
import 'package:nearsend/platform/platform_file_actions.dart';

typedef TaskAction = VoidCallback;

class TaskDetailPage extends StatelessWidget {
  const TaskDetailPage({
    super.key,
    required this.controller,
    required this.taskId,
    this.onPause,
    this.onResume,
    this.onCancel,
    this.onReconnect,
    this.onRetryFailed,
    this.fileActions,
  });

  final TaskCatalogController controller;
  final String taskId;
  final TaskAction? onPause;
  final TaskAction? onResume;
  final TaskAction? onCancel;
  final TaskAction? onReconnect;
  final TaskAction? onRetryFailed;
  final PlatformFileActions? fileActions;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? child) {
        final TaskDetail? detail = controller.detail(taskId);
        if (detail == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('任务详情')),
            body: const NsErrorState(
              title: '任务不存在',
              message: '本地数据库没有这条任务记录，可能已被清理或尚未同步。',
            ),
          );
        }
        return _TaskDetailView(
          detail: detail,
          onPause: onPause,
          onResume: onResume,
          onCancel: onCancel,
          onReconnect: onReconnect,
          onRetryFailed: onRetryFailed,
          fileActions: fileActions,
        );
      },
    );
  }
}

class _TaskDetailView extends StatelessWidget {
  const _TaskDetailView({
    required this.detail,
    this.onPause,
    this.onResume,
    this.onCancel,
    this.onReconnect,
    this.onRetryFailed,
    this.fileActions,
  });

  final TaskDetail detail;
  final TaskAction? onPause;
  final TaskAction? onResume;
  final TaskAction? onCancel;
  final TaskAction? onReconnect;
  final TaskAction? onRetryFailed;
  final PlatformFileActions? fileActions;

  static const List<String> _stages = <String>['准备', '连接', '传输', '校验', '保存'];

  @override
  Widget build(BuildContext context) {
    final TransferState state = detail.task.state;
    return Scaffold(
      appBar: AppBar(title: const Text('任务详情')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: NearSendSizing.detailMaxWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.all(NearSendSpacing.lg),
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        detail.task.taskId,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    NsStatusBadge(
                      label: _statusLabel(detail.task.status),
                      tone: _tone(detail.task.status),
                    ),
                  ],
                ),
                const SizedBox(height: NearSendSpacing.xs),
                Text(
                  _subtitle(detail.task),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: NearSendSpacing.lg),
                NsStageProgress(
                  stages: _stages,
                  activeIndex: _stageIndex(state),
                  blockedIndex: _blockedIndex(state),
                ),
                const SizedBox(height: NearSendSpacing.lg),
                if (detail.task.progress != null)
                  LinearProgressIndicator(value: detail.task.progress),
                const SizedBox(height: NearSendSpacing.sm),
                Text(
                  '${formatBytes(detail.task.committedBytes)} / ${formatBytes(detail.task.totalBytes)} 已提交',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: NearSendSpacing.md),
                _StateNotice(
                  state: state,
                  failedFileCount: detail.failedFileCount,
                ),
                const SizedBox(height: NearSendSpacing.lg),
                Text('文件', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: NearSendSpacing.sm),
                for (final TaskFileOverview file in detail.files)
                  Padding(
                    padding: const EdgeInsets.only(bottom: NearSendSpacing.sm),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        NsFileRow(
                          fileName: file.relativePath,
                          sizeLabel: formatBytes(file.sizeBytes),
                          statusLabel: _fileLabel(file),
                          progress: file.progress,
                          statusTone: _fileTone(file),
                          icon: _fileIcon(file),
                        ),
                        if (file.isSaved &&
                            file.finalTargetRef != null &&
                            fileActions != null)
                          Wrap(
                            alignment: WrapAlignment.end,
                            spacing: NearSendSpacing.xs,
                            children: <Widget>[
                              if (fileActions!.supportsOpen)
                                TextButton.icon(
                                  onPressed: () => _runFileAction(
                                    context,
                                    fileActions!.open(file.finalTargetRef!),
                                    reveal: false,
                                  ),
                                  icon: const Icon(Icons.open_in_new),
                                  label: const Text('打开'),
                                ),
                              if (fileActions!.supportsReveal)
                                TextButton.icon(
                                  onPressed: () => _runFileAction(
                                    context,
                                    fileActions!.reveal(file.finalTargetRef!),
                                    reveal: true,
                                  ),
                                  icon: const Icon(Icons.folder_open),
                                  label: const Text('显示位置'),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                if (detail.files.isEmpty)
                  const NsEmptyState(
                    title: '没有文件明细',
                    message: '任务记录尚未包含冻结清单。',
                    icon: Icons.insert_drive_file_outlined,
                  ),
                const SizedBox(height: NearSendSpacing.md),
                _actions(context, state),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _actions(BuildContext context, TransferState state) {
    final List<Widget> actions = <Widget>[];
    if ((state == TransferState.transferring ||
            state == TransferState.preparing ||
            state == TransferState.waitingAccept) &&
        onPause != null) {
      actions.add(
        NsSecondaryButton(label: '暂停', icon: Icons.pause, onPressed: onPause),
      );
    }
    if (state == TransferState.paused && onResume != null) {
      actions.add(
        NsPrimaryButton(
          label: '继续',
          icon: Icons.play_arrow,
          onPressed: onResume,
        ),
      );
    }
    if ((state == TransferState.interrupted ||
            state == TransferState.blocked) &&
        onReconnect != null) {
      actions.add(
        NsPrimaryButton(
          label: '重新连接',
          icon: Icons.link,
          onPressed: onReconnect,
        ),
      );
    }
    if ((state == TransferState.partiallyCompleted ||
            state == TransferState.failed) &&
        onRetryFailed != null) {
      actions.add(
        NsPrimaryButton(
          label: state == TransferState.partiallyCompleted ? '仅重试失败项' : '重试',
          icon: Icons.refresh,
          onPressed: onRetryFailed,
        ),
      );
    }
    if (state != TransferState.completed &&
        state != TransferState.cancelled &&
        state != TransferState.failed &&
        state != TransferState.partiallyCompleted &&
        onCancel != null) {
      actions.add(
        NsDangerButton(
          label: '取消',
          icon: Icons.close,
          onPressed: () => _confirmCancel(context),
        ),
      );
    }
    if (actions.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int index = 0; index < actions.length; index++) ...<Widget>[
          if (index > 0) const SizedBox(height: NearSendSpacing.sm),
          actions[index],
        ],
      ],
    );
  }

  Future<void> _confirmCancel(BuildContext context) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('取消这次任务？'),
        content: const Text('已保存到用户位置的文件不会删除；未完成的恢复数据会失去继续传输的机会。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续任务'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认取消'),
          ),
        ],
      ),
    );
    if (confirmed == true) onCancel?.call();
  }

  Future<void> _runFileAction(
    BuildContext context,
    Future<PlatformFileActionResult> operation, {
    required bool reveal,
  }) async {
    final PlatformFileActionResult result = await operation;
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(platformFileActionMessage(result, reveal: reveal)),
      ),
    );
  }

  static String _subtitle(TaskOverview task) {
    final String direction = task.direction.wireValue == 'server_to_client'
        ? '发送'
        : '接收';
    final String peer = task.peerName?.trim().isNotEmpty == true
        ? task.peerName!
        : '未记录对端设备';
    return '$direction · $peer · ${task.fileCount} 个文件';
  }

  static NsStatusTone _tone(TaskOverviewStatus status) => switch (status) {
    TaskOverviewStatus.active => NsStatusTone.active,
    TaskOverviewStatus.paused ||
    TaskOverviewStatus.recoverable => NsStatusTone.warning,
    TaskOverviewStatus.completed => NsStatusTone.success,
    TaskOverviewStatus.partial ||
    TaskOverviewStatus.failed => NsStatusTone.error,
  };

  static String _statusLabel(TaskOverviewStatus status) => switch (status) {
    TaskOverviewStatus.active => '活动',
    TaskOverviewStatus.paused => '已暂停',
    TaskOverviewStatus.recoverable => '可恢复',
    TaskOverviewStatus.completed => '已完成',
    TaskOverviewStatus.partial => '部分失败',
    TaskOverviewStatus.failed => '失败',
  };

  static int _stageIndex(TransferState state) => switch (state) {
    TransferState.preparing || TransferState.staging => 0,
    TransferState.waitingAccept || TransferState.ready => 1,
    TransferState.transferring ||
    TransferState.pausing ||
    TransferState.paused ||
    TransferState.interrupted ||
    TransferState.checkingResume => 2,
    TransferState.verifying => 3,
    TransferState.exporting => 4,
    TransferState.completed => 5,
    TransferState.partiallyCompleted ||
    TransferState.blocked ||
    TransferState.failed ||
    TransferState.cancelled => 2,
  };

  static int? _blockedIndex(TransferState state) => switch (state) {
    TransferState.failed || TransferState.partiallyCompleted => 3,
    TransferState.blocked || TransferState.interrupted => 2,
    _ => null,
  };

  static String _fileLabel(TaskFileOverview file) {
    if (file.isSaved) return '已校验并保存';
    if (file.exportResult == 'failed') return '保存失败，可重试';
    return switch (file.state) {
      FileState.pending => '等待处理',
      FileState.preparing => '准备中',
      FileState.transferring => '传输中',
      FileState.verifying => '校验中',
      FileState.exporting => '保存中',
      FileState.completed => '已完成，但保存记录不完整',
      FileState.failed => '失败',
      FileState.skipped => '已跳过',
    };
  }

  static NsStatusTone _fileTone(TaskFileOverview file) {
    if (file.isSaved) return NsStatusTone.success;
    if (file.isFailed) return NsStatusTone.error;
    return NsStatusTone.active;
  }

  static IconData _fileIcon(TaskFileOverview file) => file.isSaved
      ? Icons.check_circle_outline
      : file.isFailed
      ? Icons.error_outline
      : Icons.insert_drive_file_outlined;
}

class _StateNotice extends StatelessWidget {
  const _StateNotice({required this.state, required this.failedFileCount});

  final TransferState state;
  final int failedFileCount;

  @override
  Widget build(BuildContext context) {
    final (String title, String message, NsStatusTone tone) = switch (state) {
      TransferState.completed => (
        '已校验并保存',
        '所有文件都已完成终检，并且导出记录已提交。',
        NsStatusTone.success,
      ),
      TransferState.partiallyCompleted => (
        '部分文件未完成',
        '$failedFileCount 个文件失败或未保存；已完成文件不会被清理。',
        NsStatusTone.error,
      ),
      TransferState.failed => (
        '任务失败',
        '当前任务没有可用的成功确认；请查看文件状态或重新建立连接。',
        NsStatusTone.error,
      ),
      TransferState.interrupted => (
        '连接已中断',
        '已提交的块保留在本机，重新连接后只需检查并传输缺失部分。',
        NsStatusTone.warning,
      ),
      TransferState.blocked => (
        '任务需要处理',
        '权限、空间或源文件状态阻止了继续；请处理后再恢复。',
        NsStatusTone.warning,
      ),
      TransferState.paused => (
        '任务已暂停',
        '恢复前会先检查本地已接收内容，检查通过的部分无需重新传输。',
        NsStatusTone.warning,
      ),
      TransferState.checkingResume => (
        '正在校验已接收内容',
        '恢复依据是本机 SQLite 中已提交的块，不使用临时字节计数。',
        NsStatusTone.active,
      ),
      TransferState.verifying => (
        '正在校验',
        '文件仍在进行整文件校验，当前不能显示为完成。',
        NsStatusTone.active,
      ),
      TransferState.exporting => (
        '正在保存',
        '校验已通过，正在提交导出记录；完成确认尚未产生。',
        NsStatusTone.active,
      ),
      _ => ('正在处理', '任务仍在准备、连接或传输阶段。', NsStatusTone.active),
    };
    return NsInfoBanner(title: title, message: message, tone: tone);
  }
}
