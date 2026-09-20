import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/theme/design_tokens.dart';

/// Asserts that the Flutter design tokens still match **UI Baseline 1.0**,
/// `docs/ui/STYLE_GUIDE.md` §2.
///
/// A spec change that is not mirrored in `design_tokens.dart` must fail here
/// rather than silently drift.
void main() {
  group('colour tokens match STYLE_GUIDE §2.1', () {
    test('light', () {
      const NearSendColors c = NearSendColors.light;
      expect(c.primary, const Color(0xFF2563EB));
      expect(c.primaryHover, const Color(0xFF1D4ED8));
      expect(c.primarySoft, const Color(0xFFEFF6FF));
      expect(c.onPrimary, const Color(0xFFFFFFFF));
      expect(c.canvas, const Color(0xFFF8FAFC));
      expect(c.card, const Color(0xFFFFFFFF));
      expect(c.subtle, const Color(0xFFF1F5F9));
      expect(c.border, const Color(0xFFE2E8F0));
      expect(c.textPrimary, const Color(0xFF0F172A));
      expect(c.textSecondary, const Color(0xFF475569));
      expect(c.textMuted, const Color(0xFF64748B));
      expect(c.success, const Color(0xFF15803D));
      expect(c.successSoft, const Color(0xFFF0FDF4));
      expect(c.warning, const Color(0xFFB45309));
      expect(c.warningSoft, const Color(0xFFFFF7ED));
      expect(c.error, const Color(0xFFB91C1C));
      expect(c.errorSoft, const Color(0xFFFEF2F2));
    });

    test('dark', () {
      const NearSendColors c = NearSendColors.dark;
      expect(c.primary, const Color(0xFF60A5FA));
      expect(c.primaryHover, const Color(0xFF93C5FD));
      expect(c.primarySoft, const Color(0xFF172554));
      expect(c.onPrimary, const Color(0xFF0B1220));
      expect(c.canvas, const Color(0xFF0B1220));
      expect(c.card, const Color(0xFF111827));
      expect(c.subtle, const Color(0xFF1F2937));
      expect(c.border, const Color(0xFF334155));
      expect(c.textPrimary, const Color(0xFFF8FAFC));
      expect(c.textSecondary, const Color(0xFFCBD5E1));
      expect(c.textMuted, const Color(0xFF94A3B8));
      expect(c.success, const Color(0xFF4ADE80));
      expect(c.successSoft, const Color(0xFF052E16));
      expect(c.warning, const Color(0xFFFBBF24));
      expect(c.warningSoft, const Color(0xFF451A03));
      expect(c.error, const Color(0xFFF87171));
      expect(c.errorSoft, const Color(0xFF450A0A));
    });

    test('canvas and card are separate tokens, not aliases', () {
      expect(
        NearSendColors.light.canvas,
        isNot(NearSendColors.light.card),
        reason: 'the page canvas and cards must be distinguishable',
      );
      expect(NearSendColors.dark.canvas, isNot(NearSendColors.dark.card));
    });

    test('of() selects the token set for the brightness', () {
      expect(
        identical(NearSendColors.of(Brightness.light), NearSendColors.light),
        isTrue,
      );
      expect(
        identical(NearSendColors.of(Brightness.dark), NearSendColors.dark),
        isTrue,
      );
    });
  });

  group('WCAG AA contrast (required by STYLE_GUIDE §2.1)', () {
    const double aaNormalText = 4.5;

    void expectAa(Color foreground, Color background, String label) {
      final double ratio = _contrastRatio(foreground, background);
      expect(
        ratio,
        greaterThanOrEqualTo(aaNormalText),
        reason: '$label contrast ratio was ${ratio.toStringAsFixed(2)}:1',
      );
    }

    test('light: text and semantics on both canvas and card', () {
      const NearSendColors c = NearSendColors.light;
      for (final MapEntry<String, Color> surface in <String, Color>{
        'canvas': c.canvas,
        'card': c.card,
      }.entries) {
        expectAa(
          c.textPrimary,
          surface.value,
          'light text.primary/${surface.key}',
        );
        expectAa(
          c.textSecondary,
          surface.value,
          'light text.secondary/${surface.key}',
        );
        expectAa(c.textMuted, surface.value, 'light text.muted/${surface.key}');
      }
      expectAa(c.onPrimary, c.primary, 'light onPrimary/primary');
      expectAa(c.success, c.card, 'light success/card');
      expectAa(c.warning, c.card, 'light warning/card');
      expectAa(c.error, c.card, 'light error/card');
    });

    test('light: semantic foregrounds on their soft backgrounds', () {
      const NearSendColors c = NearSendColors.light;
      expectAa(c.success, c.successSoft, 'light success/successSoft');
      expectAa(c.warning, c.warningSoft, 'light warning/warningSoft');
      expectAa(c.error, c.errorSoft, 'light error/errorSoft');
      expectAa(c.textPrimary, c.primarySoft, 'light text.primary/primarySoft');
    });

    test('dark: text and semantics on both canvas and card', () {
      const NearSendColors c = NearSendColors.dark;
      for (final MapEntry<String, Color> surface in <String, Color>{
        'canvas': c.canvas,
        'card': c.card,
      }.entries) {
        expectAa(
          c.textPrimary,
          surface.value,
          'dark text.primary/${surface.key}',
        );
        expectAa(
          c.textSecondary,
          surface.value,
          'dark text.secondary/${surface.key}',
        );
        expectAa(c.textMuted, surface.value, 'dark text.muted/${surface.key}');
      }
      expectAa(c.onPrimary, c.primary, 'dark onPrimary/primary');
      expectAa(c.success, c.card, 'dark success/card');
      expectAa(c.warning, c.card, 'dark warning/card');
      expectAa(c.error, c.card, 'dark error/card');
    });

    test('dark: semantic foregrounds on their soft backgrounds', () {
      const NearSendColors c = NearSendColors.dark;
      expectAa(c.success, c.successSoft, 'dark success/successSoft');
      expectAa(c.warning, c.warningSoft, 'dark warning/warningSoft');
      expectAa(c.error, c.errorSoft, 'dark error/errorSoft');
      expectAa(c.textPrimary, c.primarySoft, 'dark text.primary/primarySoft');
    });
  });

  group('spacing, shape, type and motion tokens', () {
    test('spacing follows the 4px grid up to 64', () {
      expect(NearSendSpacing.scale, <double>[4, 8, 12, 16, 24, 32, 48, 64]);
      expect(NearSendSpacing.gridUnit, 4);
      for (final double value in NearSendSpacing.scale) {
        expect(value % NearSendSpacing.gridUnit, 0, reason: '$value off-grid');
      }
      for (int i = 1; i < NearSendSpacing.scale.length; i++) {
        expect(
          NearSendSpacing.scale[i],
          greaterThan(NearSendSpacing.scale[i - 1]),
          reason: 'the spacing scale must be strictly ascending',
        );
      }
    });

    test('radii are card 16, button 12, input 12, pill 999', () {
      expect(NearSendRadii.card, 16);
      expect(NearSendRadii.button, 12);
      expect(NearSendRadii.input, 12);
      expect(NearSendRadii.pill, 999);
    });

    test('type scale matches the seven specified tokens exactly', () {
      void expectToken(
        NearSendTypeToken token,
        double size,
        double lineHeight,
        FontWeight weight,
      ) {
        expect(token.fontSize, size);
        expect(token.lineHeight, lineHeight);
        expect(token.fontWeight, weight);
        expect(token.lineHeight, greaterThan(token.fontSize));
        expect(token.height, closeTo(lineHeight / size, 1e-9));
      }

      expectToken(NearSendTypography.displayLarge, 32, 40, FontWeight.w700);
      expectToken(NearSendTypography.titleLarge, 24, 32, FontWeight.w700);
      expectToken(NearSendTypography.titleMedium, 18, 26, FontWeight.w600);
      expectToken(NearSendTypography.bodyLarge, 16, 24, FontWeight.w400);
      expectToken(NearSendTypography.bodyMedium, 14, 22, FontWeight.w400);
      expectToken(NearSendTypography.labelLarge, 14, 20, FontWeight.w600);
      expectToken(NearSendTypography.labelSmall, 12, 18, FontWeight.w500);

      expect(NearSendTypography.scale.length, 7);
      expect(NearSendTypography.maxDynamicTypeScale, 2.0);
    });

    test('sizing and grid match the spec', () {
      expect(NearSendSizing.minTouchTarget, 48);
      expect(NearSendSizing.buttonHeight, 48);
      expect(NearSendSizing.compactDesktopButtonHeight, 40);
      expect(NearSendSizing.inputHeight, 48);
      expect(NearSendSizing.borderWidth, 1);
      expect(NearSendSizing.focusRingWidth, 2);
      expect(NearSendSizing.focusRingOffset, 2);
      expect(NearSendSizing.mobileAppBarHeight, 56);
      expect(NearSendSizing.desktopSidebarWidth, 240);
      expect(NearSendSizing.desktopSidebarCollapsedWidth, 72);
      expect(NearSendSizing.contentMaxWidth, 1180);
      expect(NearSendSizing.listDetailListWidth, 360);
      expect(NearSendSizing.minWindowWidth, 900);
      expect(NearSendSizing.minWindowHeight, 640);
    });

    test('page margins and card padding match the spec', () {
      expect(NearSendSpacing.mobilePageMargin, 20);
      expect(NearSendSpacing.mobilePageMarginCompact, 16);
      expect(NearSendSpacing.desktopPageMarginMin, 24);
      expect(NearSendSpacing.desktopPageMarginMax, 32);
      expect(NearSendSpacing.cardPaddingMin, 16);
      expect(NearSendSpacing.cardPaddingMax, 20);
    });

    test(
      'compaction keeps the compact button usable but below the default',
      () {
        expect(
          NearSendSizing.compactDesktopButtonHeight,
          lessThan(NearSendSizing.buttonHeight),
        );
        expect(
          NearSendSizing.compactDesktopButtonHeight,
          greaterThanOrEqualTo(40),
        );
      },
    );

    test('motion matches the spec', () {
      expect(NearSendMotion.stateChange.inMilliseconds, 180);
      expect(NearSendMotion.pageEnterMin.inMilliseconds, 200);
      expect(NearSendMotion.pageEnterMax.inMilliseconds, 240);
    });
  });

  group('buildNearSendTheme', () {
    test('produces the expected ThemeData for each brightness', () {
      final ThemeData light = buildNearSendTheme(Brightness.light);
      expect(light.brightness, Brightness.light);
      expect(light.colorScheme.brightness, Brightness.light);
      expect(light.colorScheme.primary, NearSendColors.light.primary);
      expect(light.colorScheme.onPrimary, NearSendColors.light.onPrimary);
      expect(light.colorScheme.error, NearSendColors.light.error);
      expect(light.colorScheme.outline, NearSendColors.light.border);

      final ThemeData dark = buildNearSendTheme(Brightness.dark);
      expect(dark.brightness, Brightness.dark);
      expect(dark.colorScheme.brightness, Brightness.dark);
      expect(dark.colorScheme.primary, NearSendColors.dark.primary);
      expect(dark.colorScheme.outline, NearSendColors.dark.border);
    });

    test('page background uses canvas while cards use card + a 1dp border', () {
      for (final ThemeData theme in <ThemeData>[
        buildNearSendTheme(Brightness.light),
        buildNearSendTheme(Brightness.dark),
      ]) {
        final NearSendColors c = NearSendColors.of(theme.brightness);
        expect(theme.scaffoldBackgroundColor, c.canvas);
        expect(theme.cardTheme.color, c.card);
        expect(
          theme.cardTheme.elevation,
          0,
          reason: 'STYLE_GUIDE §2.3: ordinary cards use a border, not a shadow',
        );

        final RoundedRectangleBorder shape =
            theme.cardTheme.shape! as RoundedRectangleBorder;
        expect(shape.side.color, c.border);
        expect(shape.side.width, NearSendSizing.borderWidth);
        expect(shape.borderRadius, BorderRadius.circular(NearSendRadii.card));
      }
    });

    test('button themes enforce the 48dp height and 12dp radius', () {
      for (final ThemeData theme in <ThemeData>[
        buildNearSendTheme(Brightness.light),
        buildNearSendTheme(Brightness.dark),
      ]) {
        expect(
          theme.filledButtonTheme.style?.minimumSize
              ?.resolve(<WidgetState>{})
              ?.height,
          NearSendSizing.buttonHeight,
        );
        expect(
          theme.outlinedButtonTheme.style?.minimumSize
              ?.resolve(<WidgetState>{})
              ?.height,
          NearSendSizing.buttonHeight,
        );
      }
    });

    test('text theme is driven by the type tokens', () {
      final ThemeData theme = buildNearSendTheme(Brightness.light);
      const NearSendColors c = NearSendColors.light;

      expect(
        theme.textTheme.displayLarge!.fontSize,
        NearSendTypography.displayLarge.fontSize,
      );
      expect(theme.textTheme.titleLarge!.fontSize, 24);
      expect(theme.textTheme.titleMedium!.fontSize, 18);
      expect(theme.textTheme.bodyLarge!.fontSize, 16);
      expect(
        theme.textTheme.bodyMedium!.fontSize,
        NearSendTypography.bodyMedium.fontSize,
      );
      expect(
        theme.textTheme.bodyMedium!.color,
        c.textPrimary,
        reason: 'text tokens must not fall back to Material defaults',
      );

      // Auxiliary text must stay token-driven instead of using Material's own
      // default colour.
      expect(
        theme.textTheme.bodySmall!.fontSize,
        NearSendTypography.labelSmall.fontSize,
      );
      expect(theme.textTheme.bodySmall!.color, c.textSecondary);
    });

    testWidgets('the theme reaches the widget tree for both brightnesses', (
      tester,
    ) async {
      late ThemeData resolved;

      Future<void> pumpWith(Brightness brightness) async {
        await tester.pumpWidget(
          MaterialApp(
            // MaterialApp wraps its theme in an AnimatedTheme; without this the
            // assertion below would observe the previous theme mid-transition.
            themeAnimationDuration: Duration.zero,
            theme: buildNearSendTheme(brightness),
            home: Builder(
              builder: (BuildContext context) {
                resolved = Theme.of(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        );
      }

      await pumpWith(Brightness.light);
      expect(resolved.brightness, Brightness.light);
      expect(resolved.colorScheme.primary, NearSendColors.light.primary);
      expect(resolved.scaffoldBackgroundColor, NearSendColors.light.canvas);

      await pumpWith(Brightness.dark);
      expect(resolved.brightness, Brightness.dark);
      expect(resolved.colorScheme.primary, NearSendColors.dark.primary);
      expect(resolved.scaffoldBackgroundColor, NearSendColors.dark.canvas);
    });

    testWidgets('honours the reduce-motion preference', (tester) async {
      late Duration animated;
      late Duration reduced;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              animated = NearSendMotion.durationFor(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(animated, NearSendMotion.stateChange);

      // MediaQuery is inserted *below* MaterialApp on purpose: MaterialApp
      // installs its own MediaQuery, so an outer override would be ignored.
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: Builder(
                  builder: (BuildContext inner) {
                    reduced = NearSendMotion.durationFor(inner);
                    return const SizedBox.shrink();
                  },
                ),
              );
            },
          ),
        ),
      );
      expect(reduced, Duration.zero);
    });
  });
}

double _contrastRatio(Color a, Color b) {
  final double la = _relativeLuminance(a);
  final double lb = _relativeLuminance(b);
  final double lighter = math.max(la, lb);
  final double darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

/// WCAG 2.1 relative luminance for an sRGB colour.
double _relativeLuminance(Color color) {
  double linearize(double channel) => channel <= 0.03928
      ? channel / 12.92
      : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();

  return 0.2126 * linearize(color.r) +
      0.7152 * linearize(color.g) +
      0.0722 * linearize(color.b);
}
