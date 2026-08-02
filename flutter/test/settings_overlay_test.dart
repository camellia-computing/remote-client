import 'package:camellia_remote_app/common/widgets/settings_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('desktop settings overlay has a persistent root header', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showSettingsOverlay<void>(
                context: context,
                title: 'Settings',
                builder: (_) => const ColoredBox(
                  color: Colors.transparent,
                  child: Center(child: Text('General content')),
                ),
              ),
              child: const Text('Open settings'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('General content'), findsOneWidget);
    final closeTooltip = MaterialLocalizations.of(
      tester.element(find.text('Settings')),
    ).closeButtonTooltip;
    expect(find.byTooltip(closeTooltip), findsOneWidget);

    await tester.tap(find.byTooltip(closeTooltip));
    await tester.pumpAndSettle();
    expect(find.text('General content'), findsNothing);
  });
}
