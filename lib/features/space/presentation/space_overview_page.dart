import 'package:flutter/material.dart';

import 'package:nearsend/app/application/space_overview_controller.dart';
import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/app/widgets/near_send_widgets.dart';
import 'package:nearsend/core/storage/space_plan.dart';

class SpaceOverviewPage extends StatefulWidget {
  const SpaceOverviewPage({super.key, required this.controller});

  final SpaceOverviewController controller;

  @override
  State<SpaceOverviewPage> createState() => _SpaceOverviewPageState();
}

class _SpaceOverviewPageState extends State<SpaceOverviewPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? child) {
        final SpaceOverview overview = widget.controller.overview;
        return Scaffold(
          appBar: AppBar(
            title: const Text('空间'),
            actions: <Widget>[
              IconButton(
                onPressed: widget.controller.refresh,
                icon: const Icon(Icons.refresh),
                tooltip: '刷新空间',
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(NearSendSpacing.lg),
            children: <Widget>[
              if (widget.controller.error != null)
                const NsErrorState(
                  title: '空间读取失败',
                  message: '无法测量保存位置的可用空间。请在接收前再次确认位置和空间。',
                )
              else if (overview.hasUnknown)
                const NsInfoBanner(
                  title: '空间未知',
                  message: '当前平台无法确认可用空间，不能把这个位置显示为检查通过。',
                  tone: NsStatusTone.warning,
                ),
              const SizedBox(height: NearSendSpacing.md),
              for (final SpaceVolumeOverview volume in overview.volumes)
                Padding(
                  padding: const EdgeInsets.only(bottom: NearSendSpacing.sm),
                  child: NsSpaceBreakdown(
                    title: volume.label,
                    status: _status(volume),
                    statusLabel: _statusLabel(volume),
                    lines: <NsSpaceLine>[
                      NsSpaceLine(
                        label: '可用空间',
                        value: _freeLabel(volume.availability),
                      ),
                      NsSpaceLine(
                        label: '本次新增需求',
                        value: volume.requiredBytes == null
                            ? '无待接收文件'
                            : _formatBytes(volume.requiredBytes!),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: NearSendSpacing.md),
              Text('已接收文件', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: NearSendSpacing.sm),
              if (overview.savedFiles.isEmpty)
                const NsInfoBanner(
                  title: '暂无已保存的接收文件',
                  message: '校验并成功保存到本机的文件会显示在这里。',
                  tone: NsStatusTone.info,
                )
              else
                for (final file in overview.savedFiles)
                  Card(
                    margin: const EdgeInsets.only(bottom: NearSendSpacing.sm),
                    child: ListTile(
                      leading: const Icon(Icons.check_circle_outline),
                      title: Text(file.fileName),
                      subtitle: SelectableText('保存位置：${file.destination}'),
                      trailing: Text(_formatBytes(file.sizeBytes)),
                    ),
                  ),
              const NsInfoBanner(
                title: '清理范围',
                message: '已导出的用户文件不属于清理范围。清理入口会在有真实可删除的暂存数据时启用。',
                tone: NsStatusTone.info,
              ),
            ],
          ),
        );
      },
    );
  }

  static NsSpaceStatus _status(SpaceVolumeOverview volume) {
    if (volume.requiredBytes == null && volume.availability.isKnown) {
      return NsSpaceStatus.measured;
    }
    return switch (volume.verdict) {
      SpaceVerdict.sufficient => NsSpaceStatus.sufficient,
      SpaceVerdict.insufficient => NsSpaceStatus.insufficient,
      SpaceVerdict.unknown => NsSpaceStatus.unknown,
    };
  }

  static String _statusLabel(SpaceVolumeOverview volume) {
    if (volume.requiredBytes == null && volume.availability.isKnown) {
      return '容量已读取';
    }
    return switch (volume.verdict) {
      SpaceVerdict.sufficient => '空间充足',
      SpaceVerdict.insufficient => '空间不足',
      SpaceVerdict.unknown => '无法确认',
    };
  }

  static String _freeLabel(VolumeAvailability availability) =>
      availability.freeBytes == null
      ? '未知'
      : _formatBytes(availability.freeBytes!);

  static String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
  }
}
