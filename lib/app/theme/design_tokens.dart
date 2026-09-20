/// NearSend design tokens.
///
/// Every value in this file is taken verbatim from `docs/ui/UI_UX_SPEC.md` §5
/// (视觉基础). That document is the authority; this file is the single place
/// where the values are expressed for Flutter.
///
/// `test/app/theme/design_tokens_test.dart` asserts that these values still
/// match the spec, so a spec change that is not mirrored here fails the build
/// instead of silently drifting.
///
/// UI_UX_SPEC §5 also requires that color is never the only signal for a state
/// (always paired with an icon, title or text) and that all foreground and
/// background combinations meet WCAG AA contrast. The contrast part is enforced
/// by the same test.
library;

import 'package:flutter/material.dart';

/// Color tokens from UI_UX_SPEC §5 "色彩 Token".
@immutable
class NearSendPalette {
  const NearSendPalette({
    required this.primary,
    required this.onPrimary,
    required this.surface,
    required this.surfaceAlt,
    required this.textPrimary,
    required this.textSecondary,
    required this.success,
    required this.warning,
    required this.error,
  });

  /// 主操作、当前阶段
  final Color primary;

  /// 主色上的文字
  final Color onPrimary;

  /// 页面/卡片
  final Color surface;

  /// 次级分区
  final Color surfaceAlt;

  /// 主要文字
  final Color textPrimary;

  /// 辅助文字
  final Color textSecondary;

  /// 已校验并保存
  final Color success;

  /// 空间未知、可恢复风险
  final Color warning;

  /// 安全、完整性、不可完成
  final Color error;

  static const NearSendPalette light = NearSendPalette(
    primary: Color(0xFF2563EB),
    onPrimary: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFF1F5F9),
    textPrimary: Color(0xFF0F172A),
    textSecondary: Color(0xFF475569),
    success: Color(0xFF15803D),
    warning: Color(0xFFB45309),
    error: Color(0xFFB91C1C),
  );

  static const NearSendPalette dark = NearSendPalette(
    primary: Color(0xFF60A5FA),
    onPrimary: Color(0xFF0B1220),
    surface: Color(0xFF111827),
    surfaceAlt: Color(0xFF1F2937),
    textPrimary: Color(0xFFF8FAFC),
    textSecondary: Color(0xFFCBD5E1),
    success: Color(0xFF4ADE80),
    warning: Color(0xFFFBBF24),
    error: Color(0xFFF87171),
  );

  static NearSendPalette of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}

/// 4px 基础网格 (UI_UX_SPEC §5 "字体与间距").
abstract final class NearSendSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;

  /// The complete sanctioned grid, in ascending order.
  static const List<double> grid = <double>[xxs, xs, sm, md, lg, xl];
}

/// 形状 (UI_UX_SPEC §5 "形状与动效").
abstract final class NearSendRadii {
  static const double card = 12;
  static const double button = 10;
}

/// 字体层级 (UI_UX_SPEC §5 "字体与间距").
///
/// The spec uses the platform system font and states ranges rather than a
/// single value: body 14–16sp, key progress 24–32sp, and no auxiliary text
/// below 12sp.
abstract final class NearSendTypography {
  static const double bodyMin = 14;
  static const double bodyMax = 16;
  static const double progressMin = 24;
  static const double progressMax = 32;
  static const double minimumCaption = 12;
  static const double bodyDefault = 16;
  static const double titleDefault = 20;
  static const double progressDefault = 28;
}

/// 状态切换动效 (UI_UX_SPEC §5 "形状与动效").
///
/// Callers must also honour the platform "reduce motion" setting; see
/// [NearSendMotion.durationFor].
abstract final class NearSendMotion {
  static const Duration stateChangeMin = Duration(milliseconds: 150);
  static const Duration stateChangeMax = Duration(milliseconds: 250);
  static const Duration stateChange = Duration(milliseconds: 200);

  /// Returns [Duration.zero] when the user has asked for reduced motion, and
  /// [stateChange] otherwise. UI_UX_SPEC §5 requires respecting the system
  /// "reduce motion" preference.
  static Duration durationFor(BuildContext context) {
    final bool reduceMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return reduceMotion ? Duration.zero : stateChange;
  }
}

/// 内容尺寸约束 (UI_UX_SPEC §5 "字体与间距").
abstract final class NearSendSizing {
  /// 触控目标至少 48×48dp
  static const double minTouchTarget = 48;

  /// 表单/确认约 720px
  static const double formMaxWidth = 720;

  /// 任务详情约 1080px
  static const double detailMaxWidth = 1080;
}

/// Builds the NearSend [ThemeData] for the given [brightness].
///
/// Uses the platform system font as required by UI_UX_SPEC §5 and prefers
/// borders over heavy shadows.
ThemeData buildNearSendTheme(Brightness brightness) {
  final NearSendPalette palette = NearSendPalette.of(brightness);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme(
      brightness: brightness,
      primary: palette.primary,
      onPrimary: palette.onPrimary,
      secondary: palette.primary,
      onSecondary: palette.onPrimary,
      error: palette.error,
      onError: palette.onPrimary,
      surface: palette.surface,
      onSurface: palette.textPrimary,
      surfaceContainerHighest: palette.surfaceAlt,
    ),
    scaffoldBackgroundColor: palette.surface,
    cardTheme: CardThemeData(
      color: palette.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NearSendRadii.card),
        side: BorderSide(color: palette.surfaceAlt),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(NearSendSizing.minTouchTarget),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NearSendRadii.button),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(NearSendSizing.minTouchTarget),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NearSendRadii.button),
        ),
      ),
    ),
    textTheme: TextTheme(
      bodyMedium: TextStyle(
        fontSize: NearSendTypography.bodyDefault,
        color: palette.textPrimary,
      ),
      bodySmall: TextStyle(
        fontSize: NearSendTypography.minimumCaption,
        color: palette.textSecondary,
      ),
      titleLarge: TextStyle(
        fontSize: NearSendTypography.titleDefault,
        color: palette.textPrimary,
      ),
    ),
  );
}
