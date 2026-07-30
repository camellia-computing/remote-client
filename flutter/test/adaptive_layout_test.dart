import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common/widgets/adaptive_layout.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _stateApp(AppContentState state) {
  return MaterialApp(
    home: Scaffold(
      body: AppStatePane(
        state: state,
        title: '${state.name} title',
        message: '${state.name} message',
      ),
    ),
  );
}

Widget _withReducedMotion(Widget child) {
  return MaterialApp(
    home: MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: Scaffold(body: child),
    ),
  );
}

void main() {
  test('layout breakpoints classify compact, medium and expanded widths', () {
    expect(AppLayout.forWidth(390), AppLayoutSize.compact);
    expect(AppLayout.forWidth(599), AppLayoutSize.compact);
    expect(AppLayout.forWidth(600), AppLayoutSize.medium);
    expect(AppLayout.forWidth(1023), AppLayoutSize.medium);
    expect(AppLayout.forWidth(1024), AppLayoutSize.expanded);
  });

  test('reference screenshot widths use the intended layout class', () {
    final expected = {
      1912.0: AppLayoutSize.expanded,
      1355.0: AppLayoutSize.expanded,
      1822.0: AppLayoutSize.expanded,
      522.0: AppLayoutSize.compact,
      577.0: AppLayoutSize.compact,
      592.0: AppLayoutSize.compact,
      1487.0: AppLayoutSize.expanded,
    };
    for (final entry in expected.entries) {
      expect(AppLayout.forWidth(entry.key), entry.value);
    }
  });

  testWidgets('adaptive content applies responsive padding and width cap', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AdaptiveContent(
            maxWidth: 900,
            child: SizedBox(
              key: ValueKey('content'),
              width: double.infinity,
              height: 40,
            ),
          ),
        ),
      ),
    );
    var padding = tester.widget<Padding>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('content')),
            matching: find.byType(Padding),
          )
          .first,
    );
    expect(padding.padding, const EdgeInsets.all(16));

    tester.view.physicalSize = const Size(1280, 900);
    await tester.pumpAndSettle();
    padding = tester.widget<Padding>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('content')),
            matching: find.byType(Padding),
          )
          .first,
    );
    expect(padding.padding, const EdgeInsets.all(32));
    expect(tester.getSize(find.byKey(const ValueKey('content'))).width, 836);
  });

  testWidgets('content pane renders every supported state', (tester) async {
    const busyStates = {
      AppContentState.loading,
      AppContentState.refreshing,
      AppContentState.loadingMore,
      AppContentState.submitting,
    };
    const stateIcons = {
      AppContentState.empty: Icons.inbox_outlined,
      AppContentState.noResults: Icons.search_off_rounded,
      AppContentState.error: Icons.error_outline_rounded,
      AppContentState.offline: Icons.cloud_off_outlined,
      AppContentState.disabled: Icons.block_rounded,
      AppContentState.success: Icons.check_circle_outline,
    };

    expect(AppContentState.values, hasLength(10));
    for (final state in AppContentState.values) {
      await tester.pumpWidget(_stateApp(state));
      await tester.pump(
        AppMotion.contentSwap + const Duration(milliseconds: 1),
      );

      expect(
        find.byKey(ValueKey<AppContentState>(state)),
        findsOneWidget,
        reason: state.name,
      );
      expect(find.text('${state.name} title'), findsOneWidget);
      expect(find.text('${state.name} message'), findsOneWidget);
      expect(
        find.byType(CircularProgressIndicator),
        busyStates.contains(state) ? findsOneWidget : findsNothing,
        reason: state.name,
      );
      if (stateIcons[state] case final icon?) {
        expect(find.byIcon(icon), findsOneWidget, reason: state.name);
      }
    }
  });

  testWidgets('visual motion is disabled when requested by the platform', (
    tester,
  ) async {
    Duration? duration;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              duration = AppMotion.duration(context, AppMotion.route);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(duration, Duration.zero);
  });

  testWidgets('state pane removes transition duration for reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      _withReducedMotion(
        const AppStatePane(
          state: AppContentState.empty,
          title: 'Empty',
          message: 'Nothing here',
        ),
      ),
    );

    final switcher = tester.widget<AnimatedSwitcher>(
      find.descendant(
        of: find.byType(AppStatePane),
        matching: find.byType(AnimatedSwitcher),
      ),
    );
    expect(switcher.duration, Duration.zero);

    await tester.pumpWidget(
      _withReducedMotion(
        const AppStatePane(
          state: AppContentState.error,
          title: 'Error',
          message: 'Try again',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Empty'), findsNothing);
    expect(find.text('Error'), findsOneWidget);
  });

  testWidgets('busy state uses a static indicator for reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      _withReducedMotion(
        const AppStatePane(
          state: AppContentState.loading,
          title: 'Loading',
          message: 'Please wait',
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.sync_rounded), findsOneWidget);
  });

  testWidgets('content transition swaps immediately for reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      _withReducedMotion(
        const AppStateTransition(
          stateKey: 'first',
          child: Text('First content'),
        ),
      ),
    );

    final switcher = tester.widget<AnimatedSwitcher>(
      find.descendant(
        of: find.byType(AppStateTransition),
        matching: find.byType(AnimatedSwitcher),
      ),
    );
    expect(switcher.duration, Duration.zero);

    await tester.pumpWidget(
      _withReducedMotion(
        const AppStateTransition(
          stateKey: 'second',
          child: Text('Second content'),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('First content'), findsNothing);
    expect(find.text('Second content'), findsOneWidget);
  });
}
