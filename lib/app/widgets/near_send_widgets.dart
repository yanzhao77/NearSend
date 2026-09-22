import 'package:flutter/material.dart';

import 'package:nearsend/app/theme/design_tokens.dart';

/// Semantic tones used by shared UI components. Callers choose a domain meaning,
/// never a presentation colour.
enum NsStatusTone { neutral, info, active, success, warning, error }

/// State of one transfer stage.
enum NsStageState { complete, active, pending, blocked }

/// Status of a space estimate.
enum NsSpaceStatus { sufficient, insufficient, unknown }

/// Status rendered by a task card.
enum NsTaskStatus {
  active,
  paused,
  recoverable,
  partial,
  completed,
  expired,
  failed,
}

class NsPrimaryButton extends StatelessWidget {
  const NsPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    onPressed: loading ? null : onPressed,
    icon: loading
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(icon ?? Icons.arrow_forward),
    label: Text(loading ? '处理中…' : label),
  );
}

class NsSecondaryButton extends StatelessWidget {
  const NsSecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onPressed,
    icon: Icon(icon ?? Icons.arrow_forward),
    label: Text(label),
  );
}

class NsDangerButton extends StatelessWidget {
  const NsDangerButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.delete_outline,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final NearSendColors colors = NearSendColors.of(
      Theme.of(context).brightness,
    );
    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: colors.errorSoft,
        foregroundColor: colors.error,
      ),
    );
  }
}

class NsInfoBanner extends StatelessWidget {
  const NsInfoBanner({
    super.key,
    required this.title,
    required this.message,
    required this.tone,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String message;
  final NsStatusTone tone;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final _NsSemanticStyle semantic = _NsSemanticStyle.of(context, tone);
    return Container(
      padding: const EdgeInsets.all(NearSendSpacing.md),
      decoration: BoxDecoration(
        color: semantic.softColor,
        border: Border.all(color: semantic.color),
        borderRadius: BorderRadius.circular(NearSendRadii.button),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(semantic.icon, color: semantic.color),
          const SizedBox(width: NearSendSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: NearSendSpacing.xxs),
                Text(message, style: Theme.of(context).textTheme.bodySmall),
                if (actionLabel != null && onAction != null) ...<Widget>[
                  const SizedBox(height: NearSendSpacing.xs),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: onAction,
                      child: Text(actionLabel!),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class NsStatusBadge extends StatelessWidget {
  const NsStatusBadge({super.key, required this.label, required this.tone});

  final String label;
  final NsStatusTone tone;

  @override
  Widget build(BuildContext context) {
    final _NsSemanticStyle semantic = _NsSemanticStyle.of(context, tone);
    return Semantics(
      label: label,
      child: Container(
        constraints: const BoxConstraints(minHeight: 28),
        padding: const EdgeInsets.symmetric(horizontal: NearSendSpacing.sm),
        decoration: BoxDecoration(
          color: semantic.softColor,
          borderRadius: BorderRadius.circular(NearSendRadii.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(semantic.icon, size: 16, color: semantic.color),
            const SizedBox(width: NearSendSpacing.xxs),
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: semantic.color),
            ),
          ],
        ),
      ),
    );
  }
}

class NsFileRow extends StatelessWidget {
  const NsFileRow({
    super.key,
    required this.fileName,
    required this.sizeLabel,
    required this.statusLabel,
    this.progress,
    this.statusTone = NsStatusTone.neutral,
    this.icon = Icons.insert_drive_file_outlined,
    this.onPressed,
  });

  final String fileName;
  final String sizeLabel;
  final String statusLabel;
  final double? progress;
  final NsStatusTone statusTone;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final Widget content = Container(
      padding: const EdgeInsets.all(NearSendSpacing.md),
      decoration: BoxDecoration(
        color: NearSendColors.of(Theme.of(context).brightness).subtle,
        borderRadius: BorderRadius.circular(NearSendRadii.button),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            icon,
            color: NearSendColors.of(Theme.of(context).brightness).primary,
          ),
          const SizedBox(width: NearSendSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Tooltip(
                  message: fileName,
                  child: Text(
                    _middleEllipsis(fileName),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(height: NearSendSpacing.xxs),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        statusLabel,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(width: NearSendSpacing.sm),
                    Text(
                      sizeLabel,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                if (progress != null) ...<Widget>[
                  const SizedBox(height: NearSendSpacing.xs),
                  LinearProgressIndicator(value: progress),
                ],
              ],
            ),
          ),
          const SizedBox(width: NearSendSpacing.sm),
          NsStatusBadge(label: statusLabel, tone: statusTone),
        ],
      ),
    );
    return onPressed == null
        ? content
        : Semantics(
            button: true,
            label: fileName,
            child: InkWell(
              onTap: onPressed,
              borderRadius: BorderRadius.circular(NearSendRadii.button),
              child: content,
            ),
          );
  }

  static String _middleEllipsis(String value) {
    const int maxCharacters = 42;
    if (value.runes.length <= maxCharacters) return value;
    final List<int> characters = value.runes.toList();
    final int extensionStart = value.lastIndexOf('.');
    final String extension = extensionStart > 0
        ? value.substring(extensionStart)
        : '';
    final int suffixLength = extension.runes.length;
    final int prefixLength = maxCharacters - suffixLength - 1;
    if (prefixLength < 8 || suffixLength >= maxCharacters) {
      return '${String.fromCharCodes(characters.take(maxCharacters - 1))}…';
    }
    return '${String.fromCharCodes(characters.take(prefixLength))}…$extension';
  }
}

class NsStageProgress extends StatelessWidget {
  const NsStageProgress({
    super.key,
    required this.stages,
    required this.activeIndex,
    this.blockedIndex,
  });

  final List<String> stages;
  final int activeIndex;
  final int? blockedIndex;

  @override
  Widget build(BuildContext context) {
    final bool allComplete = activeIndex >= stages.length;
    final int safeActive = activeIndex.clamp(0, stages.length - 1);
    return Semantics(
      label: '传输阶段：${stages[safeActive]}',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (int index = 0; index < stages.length; index++)
            Expanded(
              child: _NsStageItem(
                label: stages[index],
                state: blockedIndex == index
                    ? NsStageState.blocked
                    : allComplete
                    ? NsStageState.complete
                    : index < safeActive
                    ? NsStageState.complete
                    : index == safeActive
                    ? NsStageState.active
                    : NsStageState.pending,
                isLast: index == stages.length - 1,
              ),
            ),
        ],
      ),
    );
  }
}

class _NsStageItem extends StatelessWidget {
  const _NsStageItem({
    required this.label,
    required this.state,
    required this.isLast,
  });

  final String label;
  final NsStageState state;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final _NsSemanticStyle semantic = _NsSemanticStyle.of(
      context,
      switch (state) {
        NsStageState.complete => NsStatusTone.success,
        NsStageState.active => NsStatusTone.active,
        NsStageState.blocked => NsStatusTone.error,
        NsStageState.pending => NsStatusTone.neutral,
      },
    );
    final Widget marker = Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: state == NsStageState.pending
            ? semantic.softColor
            : semantic.color,
        shape: BoxShape.circle,
        border: state == NsStageState.pending
            ? Border.all(color: semantic.color, width: 1.5)
            : null,
      ),
      child: Icon(semantic.icon, size: 15, color: Colors.white),
    );
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            marker,
            if (!isLast)
              Expanded(
                child: Container(
                  height: 2,
                  margin: const EdgeInsets.symmetric(
                    horizontal: NearSendSpacing.xs,
                  ),
                  color: semantic.color,
                ),
              ),
          ],
        ),
        const SizedBox(height: NearSendSpacing.xs),
        Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: semantic.color),
        ),
      ],
    );
  }
}

class NsSpaceLine {
  const NsSpaceLine({required this.label, required this.value});

  final String label;
  final String value;
}

class NsSpaceBreakdown extends StatelessWidget {
  const NsSpaceBreakdown({
    super.key,
    required this.title,
    required this.status,
    required this.statusLabel,
    required this.lines,
    this.shortfallLabel,
  });

  final String title;
  final NsSpaceStatus status;
  final String statusLabel;
  final List<NsSpaceLine> lines;
  final String? shortfallLabel;

  @override
  Widget build(BuildContext context) {
    final NsStatusTone tone = switch (status) {
      NsSpaceStatus.sufficient => NsStatusTone.success,
      NsSpaceStatus.insufficient => NsStatusTone.error,
      NsSpaceStatus.unknown => NsStatusTone.warning,
    };
    final _NsSemanticStyle semantic = _NsSemanticStyle.of(context, tone);
    return Container(
      padding: const EdgeInsets.all(NearSendSpacing.md),
      decoration: BoxDecoration(
        color: semantic.softColor,
        border: Border.all(color: semantic.color),
        borderRadius: BorderRadius.circular(NearSendRadii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(semantic.icon, color: semantic.color),
              const SizedBox(width: NearSendSpacing.sm),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              NsStatusBadge(label: statusLabel, tone: tone),
            ],
          ),
          const SizedBox(height: NearSendSpacing.sm),
          for (final NsSpaceLine line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: NearSendSpacing.xxs),
              child: Row(
                children: <Widget>[
                  Expanded(child: Text(line.label)),
                  Text(
                    line.value,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ],
              ),
            ),
          if (shortfallLabel != null)
            Text(
              shortfallLabel!,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: semantic.color),
            ),
        ],
      ),
    );
  }
}

class NsTaskCard extends StatelessWidget {
  const NsTaskCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.statusLabel,
    this.progress,
    this.progressLabel,
    this.onPressed,
  });

  final String title;
  final String subtitle;
  final NsTaskStatus status;
  final String statusLabel;
  final double? progress;
  final String? progressLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final NsStatusTone tone = switch (status) {
      NsTaskStatus.active => NsStatusTone.active,
      NsTaskStatus.paused || NsTaskStatus.recoverable => NsStatusTone.warning,
      NsTaskStatus.partial ||
      NsTaskStatus.failed ||
      NsTaskStatus.expired => NsStatusTone.error,
      NsTaskStatus.completed => NsStatusTone.success,
    };
    final Widget card = Card(
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(NearSendRadii.card),
        child: Padding(
          padding: const EdgeInsets.all(NearSendSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: NearSendSpacing.xxs),
                        Text(
                          subtitle,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  NsStatusBadge(label: statusLabel, tone: tone),
                ],
              ),
              if (progress != null) ...<Widget>[
                const SizedBox(height: NearSendSpacing.md),
                LinearProgressIndicator(value: progress),
                if (progressLabel != null) ...<Widget>[
                  const SizedBox(height: NearSendSpacing.xs),
                  Text(
                    progressLabel!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
    return onPressed == null
        ? card
        : Semantics(button: true, label: title, child: card);
  }
}

class NsEmptyState extends StatelessWidget {
  const NsEmptyState({
    super.key,
    required this.title,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(NearSendSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            icon,
            size: 48,
            color: NearSendColors.of(Theme.of(context).brightness).textMuted,
          ),
          const SizedBox(height: NearSendSpacing.md),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: NearSendSpacing.xs),
          Text(
            message,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          if (actionLabel != null && onAction != null) ...<Widget>[
            const SizedBox(height: NearSendSpacing.md),
            NsSecondaryButton(
              label: actionLabel!,
              onPressed: onAction,
              icon: Icons.refresh,
            ),
          ],
        ],
      ),
    ),
  );
}

class NsErrorState extends StatelessWidget {
  const NsErrorState({
    super.key,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => NsInfoBanner(
    title: title,
    message: message,
    tone: NsStatusTone.error,
    actionLabel: actionLabel,
    onAction: onAction,
  );
}

class NsPermissionExplainer extends StatelessWidget {
  const NsPermissionExplainer({
    super.key,
    required this.title,
    required this.message,
    this.onOpenSettings,
  });

  final String title;
  final String message;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) => NsInfoBanner(
    title: title,
    message: message,
    tone: NsStatusTone.warning,
    actionLabel: onOpenSettings == null ? null : '打开系统设置',
    onAction: onOpenSettings,
  );
}

class _NsSemanticStyle {
  const _NsSemanticStyle({
    required this.color,
    required this.softColor,
    required this.icon,
  });

  final Color color;
  final Color softColor;
  final IconData icon;

  static _NsSemanticStyle of(BuildContext context, NsStatusTone tone) {
    final NearSendColors colors = NearSendColors.of(
      Theme.of(context).brightness,
    );
    return switch (tone) {
      NsStatusTone.neutral => _NsSemanticStyle(
        color: colors.textSecondary,
        softColor: colors.subtle,
        icon: Icons.circle_outlined,
      ),
      NsStatusTone.info => _NsSemanticStyle(
        color: colors.primary,
        softColor: colors.primarySoft,
        icon: Icons.info_outline,
      ),
      NsStatusTone.active => _NsSemanticStyle(
        color: colors.primary,
        softColor: colors.primarySoft,
        icon: Icons.circle,
      ),
      NsStatusTone.success => _NsSemanticStyle(
        color: colors.success,
        softColor: colors.successSoft,
        icon: Icons.check_circle_outline,
      ),
      NsStatusTone.warning => _NsSemanticStyle(
        color: colors.warning,
        softColor: colors.warningSoft,
        icon: Icons.warning_amber_outlined,
      ),
      NsStatusTone.error => _NsSemanticStyle(
        color: colors.error,
        softColor: colors.errorSoft,
        icon: Icons.error_outline,
      ),
    };
  }
}
