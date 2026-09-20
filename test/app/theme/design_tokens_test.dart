import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/app/theme/design_tokens.dart';

/// Asserts that the Flutter design tokens still match
/// `docs/ui/UI_UX_SPEC.md` §5 (视觉基础).
///
/// A spec change that is not mirrored in `design_tokens.dart` must fail here
/// rather than silently drift.
void main() {
  group('color tokens match UI_UX_SPEC §5', () {
    test('light palette', () {
      expect(NearSendPalette.light.primary, const Color(0xFF2563EB));
      expect(NearSendPalette.light.onPrimary, const Color(0xFFFFFFFF));
      expect(NearSendPalette.light.surface, const Color(0xFFFFFFFF));
      expect(NearSendPalette.light.surfaceAlt, const Color(0xFFF1F5F9));
      expect(NearSendPalette.light.textPrimary, const Color(0xFF0F172A));
      expect(NearSendPalette.light.textSecondary, const Color(0xFF475569));
      expect(NearSendPalette.light.success, const Color(0xFF15803D));
      expect(NearSendPalette.light.warning, const Color(0xFFB45309));
      expect(NearSendPalette.light.error, const Color(0xFFB91C1C));
    });

    test('dark palette', () {
      expect(NearSendPalette.dark.primary, const Color(0xFF60A5FA));
      expect(NearSendPalette.dark.onPrimary, const Color(0xFF0B1220));
      expect(NearSendPalette.dark.surface, const Color(0xFF111827));
      expect(NearSendPalette.dark.surfaceAlt, const Color(0xFF1F2937));
      expect(NearSendPalette.dark.textPrimary, const Color(0xFFF8FAFC));
      expect(NearSendPalette.dark.textSecondary, const Color(0xFFCBD5E1));
      expect(NearSendPalette.dark.success, const Color(0xFF4ADE80));
      expect(NearSendPalette.dark.warning, const Color(0xFFFBBF24));
      expect(NearSendPalette.dark.error, const Color(0xFFF87171));
    });

    test('of() selects the palette for the brightness', () {
      expect(NearSendPalette.of(Brightness.light), NearSendPalette.light);
      expect(NearSendPalette.of(Brightness.dark), NearSendPalette.dark);
    });
  });

  group(
    'WCAG AA contrast (UI_UX_SPEC §5 requires AA for all combinations)',
    () {
      const double aaNormalText = 4.5;

      void expectAa(Color foreground, Color background, String label) {
        final double ratio = _contrastRatio(foreground, background);
        expect(
          ratio,
          greaterThanOrEqualTo(aaNormalText),
          reason: '$label contrast ratio was ${ratio.toStringAsFixed(2)}:1',
        );
      }

      test('light palette foreground/background pairs reach AA', () {
        const NearSendPalette p = NearSendPalette.light;
        expectAa(p.textPrimary, p.surface, 'light textPrimary on surface');
        expectAa(p.textSecondary, p.surface, 'light textSecondary on surface');
        expectAa(p.onPrimary, p.primary, 'light onPrimary on primary');
        expectAa(p.success, p.surface, 'light success on surface');
        expectAa(p.warning, p.surface, 'light warning on surface');
        expectAa(p.error, p.surface, 'light error on surface');
      });

      test('dark palette foreground/background pairs reach AA', () {
        const NearSendPalette p = NearSendPalette.dark;
        expectAa(p.textPrimary, p.surface, 'dark textPrimary on surface');
        expectAa(p.textSecondary, p.surface, 'dark textSecondary on surface');
        expectAa(p.onPrimary, p.primary, 'dark onPrimary on primary');
        expectAa(p.success, p.surface, 'dark success on surface');
        expectAa(p.warning, p.surface, 'dark warning on surface');
        expectAa(p.error, p.surface, 'dark error on surface');
      });
    },
  );

  group('spacing, shape, type and motion tokens', () {
    test('spacing follows the 4px base grid', () {
      expect(NearSendSpacing.grid, <double>[4, 8, 12, 16, 24, 32]);
      for (final double value in NearSendSpacing.grid) {
        expect(value % 4, 0, reason: '$value must sit on the 4px grid');
      }
      expect(
        NearSendSpacing.grid,
        containsAll(<double>[
          NearSendSpacing.xxs,
          NearSendSpacing.xs,
          NearSendSpacing.sm,
          NearSendSpacing.md,
          NearSendSpacing.lg,
          NearSendSpacing.xl,
        ]),
      );
    });

    test('radii are card 12 and button 10', () {
      expect(NearSendRadii.card, 12);
      expect(NearSendRadii.button, 10);
    });

    test('type scale matches the specified ranges', () {
      expect(NearSendTypography.bodyMin, 14);
      expect(NearSendTypography.bodyMax, 16);
      expect(NearSendTypography.progressMin, 24);
      expect(NearSendTypography.progressMax, 32);
      expect(NearSendTypography.minimumCaption, 12);
      expect(
        NearSendTypography.bodyDefault,
        inInclusiveRange(
          NearSendTypography.bodyMin,
          NearSendTypography.bodyMax,
        ),
      );
      expect(
        NearSendTypography.progressDefault,
        inInclusiveRange(
          NearSendTypography.progressMin,
          NearSendTypography.progressMax,
        ),
      );
    });

    test('state change motion stays within 150-250ms', () {
      expect(NearSendMotion.stateChangeMin.inMilliseconds, 150);
      expect(NearSendMotion.stateChangeMax.inMilliseconds, 250);
      expect(
        NearSendMotion.stateChange.inMilliseconds,
        inInclusiveRange(
          NearSendMotion.stateChangeMin.inMilliseconds,
          NearSendMotion.stateChangeMax.inMilliseconds,
        ),
      );
    });

    test('sizing constraints match the spec', () {
      expect(NearSendSizing.minTouchTarget, 48);
      expect(NearSendSizing.formMaxWidth, 720);
      expect(NearSendSizing.detailMaxWidth, 1080);
    });
  });

  group('buildNearSendTheme', () {
    test('produces the expected ThemeData for each brightness', () {
      final ThemeData light = buildNearSendTheme(Brightness.light);
      expect(light.brightness, Brightness.light);
      expect(light.colorScheme.brightness, Brightness.light);
      expect(light.colorScheme.primary, NearSendPalette.light.primary);
      expect(light.colorScheme.onPrimary, NearSendPalette.light.onPrimary);
      expect(light.colorScheme.error, NearSendPalette.light.error);
      expect(light.scaffoldBackgroundColor, NearSendPalette.light.surface);

      final ThemeData dark = buildNearSendTheme(Brightness.dark);
      expect(dark.brightness, Brightness.dark);
      expect(dark.colorScheme.brightness, Brightness.dark);
      expect(dark.colorScheme.primary, NearSendPalette.dark.primary);
      expect(dark.colorScheme.onPrimary, NearSendPalette.dark.onPrimary);
      expect(dark.colorScheme.error, NearSendPalette.dark.error);
      expect(dark.scaffoldBackgroundColor, NearSendPalette.dark.surface);
    });

    test('button themes enforce the 48dp minimum touch target', () {
      for (final ThemeData theme in <ThemeData>[
        buildNearSendTheme(Brightness.light),
        buildNearSendTheme(Brightness.dark),
      ]) {
        expect(
          theme.filledButtonTheme.style?.minimumSize
              ?.resolve(<WidgetState>{})
              ?.height,
          NearSendSizing.minTouchTarget,
        );
        expect(
          theme.outlinedButtonTheme.style?.minimumSize
              ?.resolve(<WidgetState>{})
              ?.height,
          NearSendSizing.minTouchTarget,
        );
      }
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
      expect(resolved.colorScheme.primary, NearSendPalette.light.primary);
      expect(resolved.scaffoldBackgroundColor, NearSendPalette.light.surface);

      await pumpWith(Brightness.dark);
      expect(resolved.brightness, Brightness.dark);
      expect(resolved.colorScheme.primary, NearSendPalette.dark.primary);
      expect(resolved.scaffoldBackgroundColor, NearSendPalette.dark.surface);
    });

    testWidgets('honours the reduce-motion preference', (tester) async {
      late Duration animated;
      late Duration reduced;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
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

/// WCAG 2.1 relative luminance for an sRGB color.
double _relativeLuminance(Color color) {
  double linearize(double channel) => channel <= 0.03928
      ? channel / 12.92
      : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();

  return 0.2126 * linearize(color.r) +
      0.7152 * linearize(color.g) +
      0.0722 * linearize(color.b);
}
