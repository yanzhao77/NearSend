import 'package:flutter/material.dart';

import 'package:nearsend/app/application/task_catalog_controller.dart';
import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/app/widgets/near_send_widgets.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';

class TaskOverviewPage extends StatefulWidget {
  const TaskOverviewPage({super.key, required this.controller});

  final TaskCatalogController controller;

  @override
  State<TaskOverviewPage> createState() => _TaskOverviewPageState();
}

class _TaskOverviewPageState extends State<TaskOverviewPage> {
  TaskCatalogFilter _filter = TaskCatalogFilter.all;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? child) {
        final List<TaskOverview> tasks = widget.controller.filtered(_filter);
        return Scaffold(
          appBar: AppBar(
            title: const Text('任务'),
            actions: <Widget>[
              IconButton(
                onPressed: widget.controller.refresh,
                icon: const Icon(Icons.refresh),
                tooltip: '刷新任务',
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(NearSendSpacing.lg),
            children: <Widget>[
              if (widget.controller.error != null)
                NsErrorState(
                  title: '任务读取失败',
                  message: '无法读取本地任务状态，请稍后重试。',
                  actionLabel: '重试',
                  onAction: widget.controller.refresh,
                )
              else ...<Widget>[
                DropdownButtonFormField<TaskCatalogFilter>(
                  initialValue: _filter,
                  decoration: const InputDecoration(labelText: '任务范围'),
                  items: const <DropdownMenuItem<TaskCatalogFilter>>[
                    DropdownMenuItem(
                      value: TaskCatalogFilter.all,
                      child: Text('全部'),
                    ),
                    DropdownMenuItem(
                      value: TaskCatalogFilter.active,
                      child: Text('活动'),
                    ),
                    DropdownMenuItem(
                      value: TaskCatalogFilter.paused,
                      child: Text('暂停'),
                    ),
                    DropdownMenuItem(
                      value: TaskCatalogFilter.recoverable,
                      child: Text('可恢复'),
                    ),
                    DropdownMenuItem(
                      value: TaskCatalogFilter.completed,
                      child: Text('已完成'),
                    ),
                    DropdownMenuItem(
                      value: TaskCatalogFilter.failed,
                      child: Text('失败和部分失败'),
                    ),
                  ],
                  onChanged: (TaskCatalogFilter? value) {
                    if (value != null) setState(() => _filter = value);
                  },
                ),
                const SizedBox(height: NearSendSpacing.md),
                if (tasks.isEmpty)
                  const NsEmptyState(
                    title: '没有任务记录',
                    message: '任务会在真实传输创建后出现在这里。',
                    icon: Icons.swap_horizontal_circle_outlined,
                  )
                else
                  for (final TaskOverview task in tasks)
                    Padding(
                      padding: const EdgeInsets.only(
                        bottom: NearSendSpacing.sm,
                      ),
                      child: NsTaskCard(
                        title: task.taskId,
                        subtitle: _subtitle(task),
                        status: _widgetStatus(task.status),
                        statusLabel: _statusLabel(task.status),
                        progress: task.progress,
                        progressLabel:
                            '${task.committedBytes} / ${task.totalBytes} B',
                        onPressed: () => Navigator.of(
                          context,
                        ).pushNamed('/task-detail', arguments: task.taskId),
                      ),
                    ),
              ],
            ],
          ),
        );
      },
    );
  }

  static String _subtitle(TaskOverview task) {
    final String direction = task.direction == TransferDirection.clientToServer
        ? '发送'
        : '接收';
    final String peer = task.peerName?.trim().isNotEmpty == true
        ? task.peerName!
        : '未记录对端设备';
    return '$direction · $peer · ${task.fileCount} 个文件';
  }

  static NsTaskStatus _widgetStatus(TaskOverviewStatus status) =>
      switch (status) {
        TaskOverviewStatus.active => NsTaskStatus.active,
        TaskOverviewStatus.paused => NsTaskStatus.paused,
        TaskOverviewStatus.recoverable => NsTaskStatus.recoverable,
        TaskOverviewStatus.completed => NsTaskStatus.completed,
        TaskOverviewStatus.partial => NsTaskStatus.partial,
        TaskOverviewStatus.failed => NsTaskStatus.failed,
      };

  static String _statusLabel(TaskOverviewStatus status) => switch (status) {
    TaskOverviewStatus.active => '活动',
    TaskOverviewStatus.paused => '已暂停',
    TaskOverviewStatus.recoverable => '可恢复',
    TaskOverviewStatus.completed => '已完成',
    TaskOverviewStatus.partial => '部分失败',
    TaskOverviewStatus.failed => '失败',
  };
}
