import 'package:flutter/material.dart';

import 'package:nearsend/app/application/settings_controller.dart';
import 'package:nearsend/app/application/space_overview_controller.dart';
import 'package:nearsend/app/application/task_catalog_controller.dart';
import 'package:nearsend/features/home/presentation/home_page.dart';
import 'package:nearsend/features/settings/presentation/settings_page.dart';
import 'package:nearsend/features/space/presentation/space_overview_page.dart';
import 'package:nearsend/features/tasks/presentation/task_overview_page.dart';
import 'package:nearsend/app/widgets/near_send_widgets.dart';

/// Shared responsive application shell for phone and desktop layouts.
class NearSendAppShell extends StatefulWidget {
  const NearSendAppShell({
    super.key,
    required this.tasks,
    required this.space,
    required this.settings,
    this.deviceName = 'NearSend',
    this.connectionLabel = '连接状态未知',
    this.connectionTone = NsStatusTone.warning,
    this.onContinueTask,
  });

  final TaskCatalogController tasks;
  final SpaceOverviewController space;
  final SettingsController settings;
  final String deviceName;
  final String connectionLabel;
  final NsStatusTone connectionTone;
  final VoidCallback? onContinueTask;

  @override
  State<NearSendAppShell> createState() => _NearSendAppShellState();
}

class _NearSendAppShellState extends State<NearSendAppShell> {
  int _selectedIndex = 0;

  static const List<String> _labels = <String>['首页', '任务', '空间', '设置'];
  static const List<IconData> _icons = <IconData>[
    Icons.home_outlined,
    Icons.swap_horizontal_circle_outlined,
    Icons.storage_outlined,
    Icons.settings_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[widget.tasks, widget.settings]),
      builder: (BuildContext context, Widget? child) => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool desktop = _isDesktop(context);
          final bool compactDesktop = desktop && constraints.maxWidth < 900;
          final Widget content = FocusTraversalGroup(
            policy: ReadingOrderTraversalPolicy(),
            child: _content(context),
          );
          if (!desktop) {
            return Scaffold(
              body: content,
              bottomNavigationBar: NavigationBar(
                selectedIndex: _selectedIndex,
                onDestinationSelected: _select,
                destinations: <NavigationDestination>[
                  for (int index = 0; index < _labels.length; index++)
                    NavigationDestination(
                      icon: Icon(_icons[index]),
                      label: _labels[index],
                    ),
                ],
              ),
            );
          }

          return Scaffold(
            body: Row(
              children: <Widget>[
                NavigationRail(
                  selectedIndex: _selectedIndex,
                  onDestinationSelected: _select,
                  extended: !compactDesktop,
                  minExtendedWidth: 240,
                  minWidth: 72,
                  leading: Padding(
                    padding: const EdgeInsets.only(top: 16, bottom: 24),
                    child: compactDesktop
                        ? const Tooltip(
                            message: 'NearSend',
                            child: Icon(Icons.compare_arrows),
                          )
                        : Text(
                            'NearSend',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                  ),
                  destinations: <NavigationRailDestination>[
                    for (int index = 0; index < _labels.length; index++)
                      NavigationRailDestination(
                        icon: Icon(_icons[index]),
                        selectedIcon: Icon(_icons[index]),
                        label: Text(_labels[index]),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: content),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _content(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1180),
      child: SizedBox.expand(child: _page(context)),
    ),
  );

  Widget _page(BuildContext context) => switch (_selectedIndex) {
    0 => HomePage(
      deviceName: widget.deviceName,
      connectionLabel: widget.connectionLabel,
      connectionTone: widget.connectionTone,
      hasRecoverableTasks: widget.tasks.hasRecoverableTasks,
      recoverableTaskCount: widget.tasks.tasks
          .where((TaskOverview task) => task.isRecoverable)
          .length,
      onContinue: widget.onContinueTask,
    ),
    1 => TaskOverviewPage(controller: widget.tasks),
    2 => SpaceOverviewPage(controller: widget.space),
    _ => SettingsPage(controller: widget.settings, space: widget.space),
  };

  void _select(int index) {
    if (index == _selectedIndex) return;
    setState(() => _selectedIndex = index);
  }

  static bool _isDesktop(BuildContext context) {
    return switch (Theme.of(context).platform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => false,
    };
  }
}
