import 'package:flutter/material.dart';

import 'package:nearsend/app/application/app_settings_repository.dart';
import 'package:nearsend/app/application/settings_controller.dart';
import 'package:nearsend/app/application/space_overview_controller.dart';
import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/app/widgets/near_send_widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.controller,
    required this.space,
  });

  final SettingsController controller;
  final SpaceOverviewController space;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _deviceName;

  @override
  void initState() {
    super.initState();
    _deviceName = TextEditingController(
      text: widget.controller.settings.deviceName,
    );
  }

  @override
  void dispose() {
    _deviceName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? child) {
        final AppSettings settings = widget.controller.settings;
        if (_deviceName.text != settings.deviceName &&
            !_deviceName.selection.isValid) {
          _deviceName.text = settings.deviceName;
        }
        return Scaffold(
          appBar: AppBar(title: const Text('设置')),
          body: ListView(
            padding: const EdgeInsets.all(NearSendSpacing.lg),
            children: <Widget>[
              if (!widget.controller.isPersisted)
                const NsInfoBanner(
                  title: '设置尚未持久化',
                  message: '本机数据库尚未就绪，当前更改不会写入本地设置表。',
                  tone: NsStatusTone.warning,
                ),
              if (widget.controller.error != null) ...<Widget>[
                const SizedBox(height: NearSendSpacing.sm),
                const NsErrorState(
                  title: '设置保存失败',
                  message: '设置没有可靠地写入本地数据库，请重试。',
                ),
              ],
              TextField(
                controller: _deviceName,
                decoration: const InputDecoration(
                  labelText: '设备名',
                  helperText: '只影响新的配对会话，不会静默改变已有会话。',
                ),
                onSubmitted: widget.controller.updateDeviceName,
              ),
              const SizedBox(height: NearSendSpacing.md),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('默认接收位置'),
                subtitle: Text(settings.defaultReceiveLocation ?? '未设置'),
                trailing: widget.space.gateway.supportsDirectorySelection
                    ? IconButton(
                        onPressed: () async {
                          final String? location = await widget.space.gateway
                              .pickReceiveDirectory();
                          if (location != null) {
                            widget.controller.updateDefaultReceiveLocation(
                              location,
                            );
                          }
                        },
                        icon: const Icon(Icons.folder_open_outlined),
                        tooltip: '选择目录',
                      )
                    : null,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('减少动态效果'),
                value: settings.reduceMotion,
                onChanged: (bool value) => widget.controller.update(
                  settings.copyWith(reduceMotion: value),
                ),
              ),
              DropdownButtonFormField<AppThemePreference>(
                initialValue: settings.themePreference,
                decoration: const InputDecoration(labelText: '界面主题'),
                items: const <DropdownMenuItem<AppThemePreference>>[
                  DropdownMenuItem(
                    value: AppThemePreference.system,
                    child: Text('跟随系统'),
                  ),
                  DropdownMenuItem(
                    value: AppThemePreference.light,
                    child: Text('浅色'),
                  ),
                  DropdownMenuItem(
                    value: AppThemePreference.dark,
                    child: Text('深色'),
                  ),
                ],
                onChanged: (AppThemePreference? value) {
                  if (value != null) {
                    widget.controller.update(
                      settings.copyWith(themePreference: value),
                    );
                  }
                },
              ),
              const SizedBox(height: NearSendSpacing.lg),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pushNamed('/about'),
                icon: const Icon(Icons.info_outline),
                label: const Text('版本与诊断'),
              ),
              const SizedBox(height: NearSendSpacing.sm),
              const NsInfoBanner(
                title: '安全与隐私',
                message: '令牌、私钥、恢复密钥和文件内容不会写入设置表。更改安全设置或撤销授权需要明确确认。',
                tone: NsStatusTone.info,
              ),
            ],
          ),
        );
      },
    );
  }
}
