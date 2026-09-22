/// NearSend design tokens — **UI Baseline 1.0**.
///
/// Authority: `docs/ui/STYLE_GUIDE.md` §2 (Design Token). That document was merged
/// to master as the visual baseline, and `docs/ui/UI_UX_SPEC.md` §5 now points at it
/// as the visual delivery entry point. Where the two documents differ, the style
/// guide's precise values win:
///
/// * card radius **16** (UI_UX_SPEC said 12) and button radius **12** (said 10);
/// * a page-level `canvas` colour distinct from the `card` colour;
/// * additional `primaryHover`, `primarySoft`, `border`, `textMuted` and the three
///   `*Soft` semantic backgrounds;
/// * a fixed seven-step type scale instead of size ranges;
/// * the spacing scale extends to 48 and 64.
///
/// `onPrimary` is the one value the style guide does not redefine, so it is taken
/// from `UI_UX_SPEC.md` §5 (#FFFFFF light / #0B1220 dark). The dark value happens
/// to equal the dark `canvas` colour, but they are separate tokens.
///
/// `test/app/theme/design_tokens_test.dart` asserts every value below against the
/// style guide, so a spec change that is not mirrored here fails the build instead
/// of drifting silently. UI_UX_SPEC §5 also requires WCAG AA contrast for all
/// foreground/background combinations; the same test enforces that.
library;

import 'package:flutter/material.dart';

/// Colour tokens, `docs/ui/STYLE_GUIDE.md` §2.1.
@immutable
class NearSendColors {
  const NearSendColors({
    required this.primary,
    required this.primaryHover,
    required this.primarySoft,
    required this.onPrimary,
    required this.canvas,
    required this.card,
    required this.subtle,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.success,
    required this.successSoft,
    required this.warning,
    required this.warningSoft,
    required this.error,
    required this.errorSoft,
  });

  /// `color.brand.primary` — 主操作、当前阶段
  final Color primary;

  /// `color.brand.primaryHover` — 桌面 hover
  final Color primaryHover;

  /// `color.brand.primarySoft` — 选中背景
  final Color primarySoft;

  /// `UI_UX_SPEC.md` §5 `onPrimary` — 主色上的文字
  final Color onPrimary;

  /// `color.surface.canvas` — 页面背景
  final Color canvas;

  /// `color.surface.card` — 卡片、弹层
  final Color card;

  /// `color.surface.subtle` — 次级分区
  final Color subtle;

  /// `color.border.default` — 边框、分隔线
  final Color border;

  /// `color.text.primary` — 标题、正文
  final Color textPrimary;

  /// `color.text.secondary` — 辅助信息
  final Color textSecondary;

  /// `color.text.muted` — 标签、时间
  final Color textMuted;

  /// `color.semantic.success` — 校验并保存成功
  final Color success;

  /// `color.semantic.successSoft` — 成功背景
  final Color successSoft;

  /// `color.semantic.warning` — 风险、空间未知
  final Color warning;

  /// `color.semantic.warningSoft` — 警告背景
  final Color warningSoft;

  /// `color.semantic.error` — 安全停止、失败
  final Color error;

  /// `color.semantic.errorSoft` — 错误背景
  final Color errorSoft;

  static const NearSendColors light = NearSendColors(
    primary: Color(0xFF2563EB),
    primaryHover: Color(0xFF1D4ED8),
    primarySoft: Color(0xFFEFF6FF),
    onPrimary: Color(0xFFFFFFFF),
    canvas: Color(0xFFF8FAFC),
    card: Color(0xFFFFFFFF),
    subtle: Color(0xFFF1F5F9),
    border: Color(0xFFE2E8F0),
    textPrimary: Color(0xFF0F172A),
    textSecondary: Color(0xFF475569),
    textMuted: Color(0xFF64748B),
    success: Color(0xFF15803D),
    successSoft: Color(0xFFF0FDF4),
    warning: Color(0xFFB45309),
    warningSoft: Color(0xFFFFF7ED),
    error: Color(0xFFB91C1C),
    errorSoft: Color(0xFFFEF2F2),
  );

  static const NearSendColors dark = NearSendColors(
    primary: Color(0xFF60A5FA),
    primaryHover: Color(0xFF93C5FD),
    primarySoft: Color(0xFF172554),
    onPrimary: Color(0xFF0B1220),
    canvas: Color(0xFF0B1220),
    card: Color(0xFF111827),
    subtle: Color(0xFF1F2937),
    border: Color(0xFF334155),
    textPrimary: Color(0xFFF8FAFC),
    textSecondary: Color(0xFFCBD5E1),
    textMuted: Color(0xFF94A3B8),
    success: Color(0xFF4ADE80),
    successSoft: Color(0xFF052E16),
    warning: Color(0xFFFBBF24),
    warningSoft: Color(0xFF451A03),
    error: Color(0xFFF87171),
    errorSoft: Color(0xFF450A0A),
  );

  static NearSendColors of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}

/// 间距与尺寸，`docs/ui/STYLE_GUIDE.md` §2.3.
///
/// 基础网格 4px，间距阶梯 4 / 8 / 12 / 16 / 24 / 32 / 48 / 64。
abstract final class NearSendSpacing {
  /// 基础网格。
  static const double gridUnit = 4;

  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
  static const double xxxl = 64;

  /// 完整且唯一允许的间距阶梯，升序。
  static const List<double> scale = <double>[
    xxs,
    xs,
    sm,
    md,
    lg,
    xl,
    xxl,
    xxxl,
  ];

  /// 手机页面水平边距；紧凑设备最低 16。
  static const double mobilePageMargin = 20;
  static const double mobilePageMarginCompact = 16;

  /// Windows 页面外边距。
  static const double desktopPageMarginMin = 24;
  static const double desktopPageMarginMax = 32;

  /// 卡片内边距。
  static const double cardPaddingMin = 16;
  static const double cardPaddingMax = 20;
}

/// 圆角，`docs/ui/STYLE_GUIDE.md` §2.3.
abstract final class NearSendRadii {
  /// 卡片圆角 16dp。
  static const double card = 16;

  /// 按钮圆角 12dp。
  static const double button = 12;

  /// 输入框圆角 12dp。
  static const double input = 12;

  /// 状态胶囊 999dp。
  static const double pill = 999;
}

/// 尺寸与栅格，`docs/ui/STYLE_GUIDE.md` §2.3 与 §5.
abstract final class NearSendSizing {
  /// 触控目标至少 48×48dp。
  static const double minTouchTarget = 48;

  /// 默认按钮高度。
  static const double buttonHeight = 48;

  /// 紧凑桌面按钮最低高度。
  static const double compactDesktopButtonHeight = 40;

  /// 输入框高度。
  static const double inputHeight = 48;

  /// 边框 1dp。
  static const double borderWidth = 1;

  /// 焦点环 2dp，外扩 2dp。
  static const double focusRingWidth = 2;
  static const double focusRingOffset = 2;

  /// 手机顶部 AppBar 高度。
  static const double mobileAppBarHeight = 56;

  /// Windows 侧栏宽度，折叠为图标栏。
  static const double desktopSidebarWidth = 240;
  static const double desktopSidebarCollapsedWidth = 72;

  /// Windows 主内容最大宽度。
  static const double contentMaxWidth = 1180;

  /// Windows 列表 + 详情双栏中的列表宽度。
  static const double listDetailListWidth = 360;

  /// Windows 最小支持窗口。
  static const double minWindowWidth = 900;
  static const double minWindowHeight = 640;

  /// UI_UX_SPEC §5 保留的表单/确认内容宽度上限（与主内容宽度是不同层级）。
  static const double formMaxWidth = 720;

  /// UI_UX_SPEC §5 保留的任务详情内容宽度上限。
  static const double detailMaxWidth = 1080;
}

/// 单个排版 Token：字号 / 行高 / 字重。
@immutable
class NearSendTypeToken {
  const NearSendTypeToken(this.fontSize, this.lineHeight, this.fontWeight);

  final double fontSize;
  final double lineHeight;
  final FontWeight fontWeight;

  /// Flutter 的 `TextStyle.height` 是行高倍数。
  double get height => lineHeight / fontSize;

  TextStyle toTextStyle(Color color) => TextStyle(
    fontSize: fontSize,
    height: height,
    fontWeight: fontWeight,
    color: color,
  );
}

/// 排版，`docs/ui/STYLE_GUIDE.md` §2.2.
///
/// 使用平台系统字体，不在安装包内嵌入大字体。
abstract final class NearSendTypography {
  static const NearSendTypeToken displayLarge = NearSendTypeToken(
    32,
    40,
    FontWeight.w700,
  );
  static const NearSendTypeToken titleLarge = NearSendTypeToken(
    24,
    32,
    FontWeight.w700,
  );
  static const NearSendTypeToken titleMedium = NearSendTypeToken(
    18,
    26,
    FontWeight.w600,
  );
  static const NearSendTypeToken bodyLarge = NearSendTypeToken(
    16,
    24,
    FontWeight.w400,
  );
  static const NearSendTypeToken bodyMedium = NearSendTypeToken(
    14,
    22,
    FontWeight.w400,
  );
  static const NearSendTypeToken labelLarge = NearSendTypeToken(
    14,
    20,
    FontWeight.w600,
  );
  static const NearSendTypeToken labelSmall = NearSendTypeToken(
    12,
    18,
    FontWeight.w500,
  );

  static const List<NearSendTypeToken> scale = <NearSendTypeToken>[
    displayLarge,
    titleLarge,
    titleMedium,
    bodyLarge,
    bodyMedium,
    labelLarge,
    labelSmall,
  ];

  /// 动态字体放大到 200% 时主操作、状态与错误原因不得截断。
  static const double maxDynamicTypeScale = 2.0;
}

/// 动效，`docs/ui/STYLE_GUIDE.md` §6.
abstract final class NearSendMotion {
  /// 状态切换 180ms。
  static const Duration stateChange = Duration(milliseconds: 180);

  /// 页面进入 200–240ms。
  static const Duration pageEnterMin = Duration(milliseconds: 200);
  static const Duration pageEnterMax = Duration(milliseconds: 240);

  /// 尊重系统「减少动态效果」设置；开启时返回零时长。
  static Duration durationFor(BuildContext context) {
    final bool reduceMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return reduceMotion ? Duration.zero : stateChange;
  }
}

/// 构建 NearSend 在指定 [brightness] 下的 [ThemeData]。
///
/// 普通卡片使用 1dp 边框而不是阴影（STYLE_GUIDE §2.3），页面背景使用 `canvas`
/// 而不是 `card` 颜色。
ThemeData buildNearSendTheme(Brightness brightness) {
  final NearSendColors colors = NearSendColors.of(brightness);
  final Color borderColor = colors.border;

  OutlineInputBorder inputBorder() => OutlineInputBorder(
    borderRadius: BorderRadius.circular(NearSendRadii.input),
    borderSide: BorderSide(
      color: borderColor,
      width: NearSendSizing.borderWidth,
    ),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme(
      brightness: brightness,
      primary: colors.primary,
      onPrimary: colors.onPrimary,
      secondary: colors.primary,
      onSecondary: colors.onPrimary,
      error: colors.error,
      onError: colors.onPrimary,
      surface: colors.canvas,
      onSurface: colors.textPrimary,
      surfaceContainerHighest: colors.subtle,
      outline: borderColor,
      outlineVariant: borderColor,
    ),
    scaffoldBackgroundColor: colors.canvas,
    visualDensity: VisualDensity.standard,
    splashFactory: InkRipple.splashFactory,
    cardTheme: CardThemeData(
      color: colors.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NearSendRadii.card),
        side: BorderSide(color: borderColor, width: NearSendSizing.borderWidth),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(NearSendSizing.buttonHeight),
        padding: const EdgeInsets.symmetric(horizontal: NearSendSpacing.lg),
        textStyle: NearSendTypography.labelLarge.toTextStyle(colors.onPrimary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NearSendRadii.button),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(NearSendSizing.buttonHeight),
        padding: const EdgeInsets.symmetric(horizontal: NearSendSpacing.lg),
        textStyle: NearSendTypography.labelLarge.toTextStyle(colors.textPrimary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NearSendRadii.button),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size.fromHeight(NearSendSizing.minTouchTarget),
        padding: const EdgeInsets.symmetric(horizontal: NearSendSpacing.md),
        textStyle: NearSendTypography.labelLarge.toTextStyle(colors.primary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NearSendRadii.button),
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size.square(NearSendSizing.minTouchTarget),
        foregroundColor: colors.textSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NearSendRadii.button),
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: colors.subtle,
      selectedColor: colors.primarySoft,
      disabledColor: colors.subtle,
      side: BorderSide(color: borderColor, width: NearSendSizing.borderWidth),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NearSendRadii.pill),
      ),
      labelStyle: NearSendTypography.labelSmall.toTextStyle(colors.textSecondary),
      secondaryLabelStyle: NearSendTypography.labelSmall.toTextStyle(
        colors.textSecondary,
      ),
      padding: const EdgeInsets.symmetric(horizontal: NearSendSpacing.sm),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.card,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NearSendRadii.card),
        side: BorderSide(color: borderColor, width: NearSendSizing.borderWidth),
      ),
      titleTextStyle: NearSendTypography.titleMedium.toTextStyle(
        colors.textPrimary,
      ),
      contentTextStyle: NearSendTypography.bodyMedium.toTextStyle(
        colors.textSecondary,
      ),
    ),
    bannerTheme: MaterialBannerThemeData(
      backgroundColor: colors.subtle,
      contentTextStyle: NearSendTypography.bodyMedium.toTextStyle(
        colors.textPrimary,
      ),
      padding: const EdgeInsets.all(NearSendSpacing.md),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: colors.textPrimary,
      contentTextStyle: NearSendTypography.bodyMedium.toTextStyle(
        colors.card,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NearSendRadii.button),
      ),
      behavior: SnackBarBehavior.floating,
    ),
    dividerTheme: DividerThemeData(
      color: borderColor,
      thickness: NearSendSizing.borderWidth,
      space: NearSendSpacing.md,
    ),
    listTileTheme: ListTileThemeData(
      minVerticalPadding: NearSendSpacing.xs,
      contentPadding: const EdgeInsets.symmetric(horizontal: NearSendSpacing.md),
      titleTextStyle: NearSendTypography.bodyMedium.toTextStyle(colors.textPrimary),
      subtitleTextStyle: NearSendTypography.labelSmall.toTextStyle(
        colors.textSecondary,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: colors.primary,
      linearTrackColor: colors.subtle,
      circularTrackColor: colors.subtle,
      linearMinHeight: 8,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.card,
      constraints: const BoxConstraints(minHeight: NearSendSizing.inputHeight),
      border: inputBorder(),
      enabledBorder: inputBorder(),
      focusedBorder: inputBorder().copyWith(
        borderSide: BorderSide(
          color: colors.primary,
          width: NearSendSizing.focusRingWidth,
        ),
      ),
      errorBorder: inputBorder().copyWith(
        borderSide: BorderSide(
          color: colors.error,
          width: NearSendSizing.borderWidth,
        ),
      ),
      focusedErrorBorder: inputBorder().copyWith(
        borderSide: BorderSide(
          color: colors.error,
          width: NearSendSizing.focusRingWidth,
        ),
      ),
      labelStyle: NearSendTypography.bodyMedium.toTextStyle(colors.textSecondary),
      hintStyle: NearSendTypography.bodyMedium.toTextStyle(colors.textMuted),
      errorStyle: NearSendTypography.labelSmall.toTextStyle(colors.error),
    ),
    textTheme: TextTheme(
      displayLarge: NearSendTypography.displayLarge.toTextStyle(
        colors.textPrimary,
      ),
      titleLarge: NearSendTypography.titleLarge.toTextStyle(colors.textPrimary),
      titleMedium: NearSendTypography.titleMedium.toTextStyle(
        colors.textPrimary,
      ),
      bodyLarge: NearSendTypography.bodyLarge.toTextStyle(colors.textPrimary),
      bodyMedium: NearSendTypography.bodyMedium.toTextStyle(colors.textPrimary),
      labelLarge: NearSendTypography.labelLarge.toTextStyle(colors.textPrimary),
      labelSmall: NearSendTypography.labelSmall.toTextStyle(
        colors.textSecondary,
      ),
      // Material's `bodySmall` is not part of the UI Baseline token set, but it is
      // the slot Flutter widgets reach for by default for auxiliary text. Map it to
      // the `label.small` token so auxiliary text stays token-driven instead of
      // falling back to Material's own default colour.
      bodySmall: NearSendTypography.labelSmall.toTextStyle(
        colors.textSecondary,
      ),
    ),
  );
}
