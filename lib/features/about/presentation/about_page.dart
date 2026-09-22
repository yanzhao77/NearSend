import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';
import 'package:nearsend/app/widgets/near_send_widgets.dart';
import 'package:nearsend/core/build_info/build_info.dart';

/// Version, protocol, schema and security diagnostics.
///
/// Every value is sourced from build/storage authorities or explicitly marked unknown. This page
/// is intentionally reachable from Settings rather than being a primary navigation destination.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static const String title = '版本与诊断';

  @override
  Widget build(BuildContext context) {
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
                Text(
                  'NearSend',
                  style: Theme.of(context).textTheme.displaySmall,
                ),
                const SizedBox(height: NearSendSpacing.xs),
                Text(
                  '本地 Wi-Fi 文件传输 · 版本与运行诊断',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: NearSendSpacing.lg),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(NearSendSpacing.md),
                    child: Column(
                      children: <Widget>[
                        _InfoRow(
                          label: '应用版本',
                          value: '$kAppVersion+$kAppBuildNumber',
                        ),
                        _InfoRow(label: 'Git 提交', value: gitShaDisplay),
                        _InfoRow(
                          label: '协议版本',
                          value:
                              '$protocolVersionDisplay · $protocolStatusDisplay',
                        ),
                        _InfoRow(
                          label: '数据库 schema 版本',
                          value: dbSchemaDisplay,
                        ),
                        _InfoRow(label: '构建渠道', value: buildChannelDisplay),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: NearSendSpacing.md),
                const NsInfoBanner(
                  title: '状态说明',
                  message:
                      '协议版本为草案，尚未冻结。数据库 schema 与迁移代码已实现；运行时是否装配由上方状态明确标记。未注入 Git 或构建渠道时显示 unknown。',
                  tone: NsStatusTone.info,
                ),
                const SizedBox(height: NearSendSpacing.md),
                const NsInfoBanner(
                  title: '安全诊断',
                  message:
                      '配对仍要求严格解析连接信息和 TLS 指纹校验。指纹变化会阻断连接；令牌、私钥、恢复密钥和文件内容不写入设置表或诊断文本。',
                  tone: NsStatusTone.success,
                ),
                const SizedBox(height: NearSendSpacing.md),
                const NsPermissionExplainer(
                  title: '平台验证状态',
                  message:
                      '当前开发环境已验证 Android 构建、macOS 桌面和 Chrome；Windows、iOS 真机与平台存储能力需要对应环境验证，不能从这里推断为通过。',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NearSendSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 160,
            child: Text(label, style: Theme.of(context).textTheme.labelSmall),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}
