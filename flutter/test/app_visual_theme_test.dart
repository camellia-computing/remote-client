import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:flutter_test/flutter_test.dart';

class _VisualSnapshot {
  const _VisualSnapshot({
    required this.brightness,
    required this.tokens,
    required this.tones,
    required this.toneContainers,
    required this.surface,
    required this.raisedSurface,
  });

  final Brightness brightness;
  final AppDesignTokens tokens;
  final Map<AppTone, Color> tones;
  final Map<AppTone, Color> toneContainers;
  final BoxDecoration surface;
  final BoxDecoration raisedSurface;
}

void main() {
  testWidgets('semantic surfaces resolve from light and dark theme tokens', (
    tester,
  ) async {
    for (final (theme, expectedTokens) in [
      (MyTheme.lightTheme, AppDesignTokens.light),
      (MyTheme.darkTheme, AppDesignTokens.dark),
    ]) {
      _VisualSnapshot? snapshot;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Builder(
            builder: (context) {
              snapshot = _VisualSnapshot(
                brightness: Theme.of(context).brightness,
                tokens: AppVisual.tokens(context),
                tones: {
                  for (final tone in AppTone.values)
                    tone: AppVisual.tone(context, tone),
                },
                toneContainers: {
                  for (final tone in AppTone.values)
                    tone: AppVisual.toneContainer(context, tone),
                },
                surface: AppVisual.surfaceDecoration(context),
                raisedSurface: AppVisual.surfaceDecoration(
                  context,
                  elevated: true,
                ),
              );
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final visual = snapshot!;
      expect(visual.brightness, theme.brightness);
      expect(visual.tokens.page, expectedTokens.page);
      expect(visual.tokens.surface, expectedTokens.surface);
      expect(visual.tokens.surfaceContainer, expectedTokens.surfaceContainer);
      expect(visual.tokens.surfaceElevated, expectedTokens.surfaceElevated);
      expect(visual.tokens.border, expectedTokens.border);
      expect(visual.tokens.controlHeight, 44);
      expect(visual.tokens.touchTarget, 48);
      expect(
        theme.focusColor,
        CamelliaColors.azure.withValues(
          alpha: theme.brightness == Brightness.light ? 0.18 : 0.28,
        ),
      );
      expect(
        theme.filledButtonTheme.style?.minimumSize?.resolve({}),
        Size(0, expectedTokens.controlHeight),
      );
      expect(visual.surface.color, expectedTokens.surface);
      expect(visual.surface.border!.top.color, expectedTokens.border);
      expect(visual.surface.boxShadow, isEmpty);
      expect(visual.raisedSurface.color, expectedTokens.surfaceElevated);
      expect(visual.raisedSurface.border!.top.color, expectedTokens.border);
      expect(visual.raisedSurface.boxShadow, hasLength(1));
      expect(
        visual.raisedSurface.boxShadow!.single.color,
        expectedTokens.shadowStrong,
      );

      expect(visual.tones[AppTone.brand], theme.colorScheme.primary);
      expect(visual.tones[AppTone.secondary], expectedTokens.secondary);
      expect(visual.tones[AppTone.info], expectedTokens.info);
      expect(visual.tones[AppTone.success], expectedTokens.success);
      expect(visual.tones[AppTone.warning], expectedTokens.warning);
      expect(visual.tones[AppTone.danger], expectedTokens.danger);
      expect(visual.tones[AppTone.neutral], expectedTokens.muted);
      expect(
        visual.toneContainers[AppTone.brand],
        expectedTokens.accentContainer,
      );
      expect(
        visual.toneContainers[AppTone.success],
        expectedTokens.success.withValues(
          alpha: theme.brightness == Brightness.light ? 0.10 : 0.18,
        ),
      );
    }
  });
}
