import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/core/build_info/build_info.dart';

/// Version, protocol and schema identity page.
///
/// T01-01 requires the application to display the version, Git commit, protocol
/// version and database schema version. This page is the single place where
/// those values are surfaced, and it labels each one with its real status so
/// that a draft protocol or a declared-only schema version can never be read as
/// a finished capability.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static const String title = '版本与诊断';

  @override
  Widget build(BuildContext context) {
    final NearSendColors palette = NearSendColors.of(
      Theme.of(context).brightness,
    );

    return Scaffold(
      appBar: AppBar(title: const Text(title)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: NearSendSizing.formMaxWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.all(NearSendSpacing.lg),
              children: <Widget>[
                Text(kAppName, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: NearSendSpacing.md),
                const _InfoRow(
                  label: '应用版本',
                  value: '$kAppVersion+$kAppBuildNumber',
                ),
                const _InfoRow(
                  label: 'Git 提交',
                  value: '-',
                  valueBuilder: _gitValue,
                ),
                const _InfoRow(
                  label: '协议版本',
                  value: '-',
                  valueBuilder: _protocolValue,
                ),
                const _InfoRow(
                  label: '数据库 schema 版本',
                  value: '-',
                  valueBuilder: _schemaValue,
                ),
                const _InfoRow(
                  label: '构建渠道',
                  value: '-',
                  valueBuilder: _channelValue,
                ),
                const SizedBox(height: NearSendSpacing.lg),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(NearSendSpacing.md),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(Icons.info_outline, color: palette.textSecondary),
                        const SizedBox(width: NearSendSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                '关于以上数值的含义',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              const SizedBox(height: NearSendSpacing.xs),
                              Text(
                                '• 协议版本为草案，尚未冻结；协议能力协商与状态模型由 T02-02 实现。\n'
                                '• 数据库 schema 版本目前只有声明值，本版本未创建任何 SQLite 数据库；真实 schema、迁移与故障测试由 T04-01 实现。\n'
                                '• Git 提交在构建时通过 --dart-define 注入；未注入时显示 unknown，不显示推测值。',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _gitValue() => gitShaDisplay;

  static String _protocolValue() =>
      '$protocolVersionDisplay · $protocolStatusDisplay';

  static String _schemaValue() => dbSchemaDisplay;

  static String _channelValue() => buildChannelDisplay;
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.valueBuilder});

  final String label;
  final String value;
  final String Function()? valueBuilder;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NearSendSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 160,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              valueBuilder?.call() ?? value,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
