import 'package:flutter/material.dart';

import 'package:nearsend/app/application/app_settings_repository.dart';
import 'package:nearsend/app/application/settings_controller.dart';
import 'package:nearsend/app/application/space_overview_controller.dart';
import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/app/widgets/near_send_widgets.dart';
import 'package:nearsend/platform/storage_location.dart';

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
  StoragePermissionState? _locationPermission;
  String? _locationError;
  bool _checkingLocation = false;

  @override
  void initState() {
    super.initState();
    _deviceName = TextEditingController(
      text: widget.controller.settings.deviceName,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _validateSavedLocation();
    });
  }

  @override
  void dispose() {
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _validateSavedLocation() async {
    final StorageLocationRef? location =
        widget.controller.settings.defaultReceiveLocation;
    if (location == null) return;
    await _validateLocation(location, persist: false);
  }

  Future<bool> _validateLocation(
    StorageLocationRef location, {
    required bool persist,
  }) async {
    setState(() {
      _checkingLocation = true;
      _locationError = null;
    });
    try {
      final StorageLocationRef validated = await widget.space.gateway
          .validateReceiveLocation(location);
      if (!mounted) return false;
      final bool granted =
          validated.permissionState == StoragePermissionState.granted;
      setState(() {
        _locationPermission = validated.permissionState;
        _locationError = granted ? null : '无法访问已保存的目录，请重新选择并授予访问权限。';
      });
      if (granted && persist) {
        widget.controller.updateDefaultReceiveLocation(validated);
      }
      return granted;
    } on Object {
      if (!mounted) return false;
      setState(() {
        _locationPermission = StoragePermissionState.unavailable;
        _locationError = '目录权限验证失败，原设置未更改。请重新选择后再试。';
      });
      return false;
    } finally {
      if (mounted) setState(() => _checkingLocation = false);
    }
  }

  Future<void> _pickReceiveLocation() async {
    try {
      final StorageLocationRef? location = await widget.space.gateway
          .pickReceiveDirectory();
      if (!mounted || location == null) return;
      await _validateLocation(location, persist: true);
    } on Object {
      if (mounted) {
        setState(() {
          _locationError = '系统目录选择器未能完成，原设置保持不变。';
        });
      }
    }
  }

  String _locationSubtitle(AppSettings settings) {
    if (settings.defaultReceiveLocationNeedsRepair) {
      return '原保存位置不可识别，请重新选择';
    }
    final StorageLocationRef? location = settings.defaultReceiveLocation;
    if (location == null) return '未设置';
    final String state = switch (_locationPermission) {
      StoragePermissionState.granted => '访问权限有效',
      StoragePermissionState.denied ||
      StoragePermissionState.unavailable => '需要重新授权',
      StoragePermissionState.unknown ||
      null => _checkingLocation ? '正在验证访问权限' : '尚未验证访问权限',
    };
    return '${location.displayName} · $state';
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
                subtitle: Text(_locationSubtitle(settings)),
                trailing: widget.space.gateway.supportsDirectorySelection
                    ? IconButton(
                        onPressed: _checkingLocation
                            ? null
                            : _pickReceiveLocation,
                        icon: const Icon(Icons.folder_open_outlined),
                        tooltip:
                            settings.defaultReceiveLocationNeedsRepair ||
                                _locationError != null
                            ? '重新选择目录'
                            : '选择目录',
                      )
                    : null,
              ),
              if (settings.defaultReceiveLocationNeedsRepair ||
                  _locationError != null) ...<Widget>[
                NsInfoBanner(
                  title: '默认接收位置需要修复',
                  message: _locationError ?? '保存的位置数据无法识别，请通过系统选择器重新选择。',
                  tone: NsStatusTone.warning,
                  actionLabel: widget.space.gateway.supportsDirectorySelection
                      ? '重新选择'
                      : null,
                  onAction: widget.space.gateway.supportsDirectorySelection
                      ? _pickReceiveLocation
                      : null,
                ),
                const SizedBox(height: NearSendSpacing.sm),
              ],
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
