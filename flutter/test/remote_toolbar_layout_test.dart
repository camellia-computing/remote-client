import 'package:camellia_remote_app/desktop/widgets/remote_toolbar_overlay.dart';
import 'package:camellia_remote_app/ui/remote_ui_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const viewport = Size(1000, 600);

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets('expanded and collapsed footprints stay docked at every edge', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    for (final edge in RemoteCommandBarEdge.values) {
      final toolbarSize = edge.isHorizontal
          ? const Size(240, 84)
          : const Size(84, 240);
      await _pumpSurface(
        tester,
        viewport: viewport,
        edge: edge,
        fraction: 0.25,
        toolbar: SizedBox(
          key: _toolbarKey,
          width: toolbarSize.width,
          height: toolbarSize.height,
        ),
      );

      final rect = tester.getRect(find.byKey(_toolbarKey));
      expect(rect.size, toolbarSize, reason: '$edge expanded footprint');
      _expectDocked(rect, viewport, edge, 0.25);
      expect(tester.takeException(), isNull);

      await _pumpSurface(
        tester,
        viewport: viewport,
        edge: edge,
        fraction: 0.75,
        toolbar: const SizedBox.square(key: _toolbarKey, dimension: 32),
      );
      final collapsedRect = tester.getRect(find.byKey(_toolbarKey));
      expect(collapsedRect.size, const Size.square(32));
      _expectDocked(collapsedRect, viewport, edge, 0.75);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('transparent overlay area passes pointer events to the canvas', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    var canvasTaps = 0;
    var toolbarTaps = 0;

    await _pumpSurface(
      tester,
      viewport: viewport,
      edge: RemoteCommandBarEdge.top,
      fraction: 0.5,
      background: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => canvasTaps++,
      ),
      toolbar: GestureDetector(
        key: _toolbarKey,
        behavior: HitTestBehavior.opaque,
        onTap: () => toolbarTaps++,
        child: const SizedBox(width: 240, height: 84),
      ),
    );

    await tester.tapAt(const Offset(950, 550));
    await tester.pump();
    expect(canvasTaps, 1);
    expect(toolbarTaps, 0);

    await tester.tap(find.byKey(_toolbarKey));
    await tester.pump();
    expect(canvasTaps, 1);
    expect(toolbarTaps, 1);

    await _pumpSurface(
      tester,
      viewport: viewport,
      edge: RemoteCommandBarEdge.top,
      fraction: 0.5,
      background: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => canvasTaps++,
      ),
      toolbar: const SizedBox.shrink(),
    );
    await tester.tapAt(const Offset(500, 10));
    await tester.pump();
    expect(canvasTaps, 2, reason: 'hidden toolbar must not retain a hit area');
    expect(tester.takeException(), isNull);
  });

  testWidgets('toolbar build failures are confined to the docking band', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    final previousErrorBuilder = ErrorWidget.builder;
    final previousErrorHandler = FlutterError.onError;
    final capturedErrors = <Object>[];
    FlutterError.onError = (details) {
      capturedErrors.add(details.exception);
    };
    ErrorWidget.builder = (details) {
      return const SizedBox.expand(
        child: ColoredBox(key: _errorWidgetKey, color: Color(0xF0C0C0C0)),
      );
    };
    addTearDown(() {
      ErrorWidget.builder = previousErrorBuilder;
      FlutterError.onError = previousErrorHandler;
    });

    await _pumpLegacySurface(
      tester,
      viewport: viewport,
      toolbar: const _ThrowingToolbarChild(),
    );
    expect(capturedErrors.last, isA<StateError>());
    expect(
      tester.getRect(find.byKey(_errorWidgetKey)).size,
      viewport,
      reason: 'the previous Align inherited the entire viewport on failure',
    );

    for (final edge in RemoteCommandBarEdge.values) {
      await _pumpSurface(
        tester,
        viewport: viewport,
        edge: edge,
        fraction: 0.5,
        toolbar: _ThrowingToolbarChild(key: ValueKey(edge)),
      );

      expect(capturedErrors.last, isA<StateError>());
      final errorRect = tester.getRect(find.byKey(_errorWidgetKey));
      if (edge.isHorizontal) {
        expect(errorRect.width, viewport.width);
        expect(errorRect.height, greaterThan(0));
        expect(
          errorRect.height,
          lessThanOrEqualTo(RemoteToolbarOverlaySurface.maxCrossAxisExtent),
        );
        expect(errorRect.height, lessThan(viewport.height));
      } else {
        expect(errorRect.height, viewport.height);
        expect(errorRect.width, greaterThan(0));
        expect(
          errorRect.width,
          lessThanOrEqualTo(RemoteToolbarOverlaySurface.maxCrossAxisExtent),
        );
        expect(errorRect.width, lessThan(viewport.width));
      }
      _expectDocked(errorRect, viewport, edge, 0.5);
    }
  });

  testWidgets('resize and device-pixel-ratio changes preserve finite bounds', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const sizes = [Size(320, 240), Size(1062, 607), Size(2560, 1440)];
    const ratios = [1.0, 1.25, 1.5, 2.0];

    for (final ratio in ratios) {
      tester.view.devicePixelRatio = ratio;
      for (final size in sizes) {
        await _pumpSurface(
          tester,
          viewport: size,
          edge: RemoteCommandBarEdge.bottom,
          fraction: 0.65,
          toolbar: const SizedBox(key: _toolbarKey, width: 240, height: 84),
        );
        final rect = tester.getRect(find.byKey(_toolbarKey));
        expect(rect.left.isFinite, isTrue);
        expect(rect.top.isFinite, isTrue);
        expect(rect.right, lessThanOrEqualTo(size.width));
        expect(rect.bottom, size.height);
        expect(tester.takeException(), isNull);
      }
    }
  });
}

const _toolbarKey = ValueKey('remote-toolbar-test-surface');
const _errorWidgetKey = ValueKey('remote-toolbar-error-widget');

class _ThrowingToolbarChild extends StatelessWidget {
  const _ThrowingToolbarChild({super.key});

  @override
  Widget build(BuildContext context) {
    throw StateError('deterministic toolbar child failure');
  }
}

Future<void> _pumpSurface(
  WidgetTester tester, {
  required Size viewport,
  required RemoteCommandBarEdge edge,
  required double fraction,
  required Widget toolbar,
  Widget background = const ColoredBox(color: Colors.black),
}) async {
  tester.view.physicalSize = viewport * tester.view.devicePixelRatio;
  await tester.pumpWidget(
    MaterialApp(
      home: Stack(
        fit: StackFit.expand,
        children: [
          background,
          RemoteToolbarOverlaySurface(
            edge: edge,
            fraction: fraction,
            toolbar: toolbar,
          ),
        ],
      ),
    ),
  );
  await tester.pump();
}

Future<void> _pumpLegacySurface(
  WidgetTester tester, {
  required Size viewport,
  required Widget toolbar,
}) async {
  tester.view.physicalSize = viewport * tester.view.devicePixelRatio;
  await tester.pumpWidget(
    MaterialApp(
      home: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          Stack(
            fit: StackFit.expand,
            children: [Align(alignment: Alignment.topCenter, child: toolbar)],
          ),
        ],
      ),
    ),
  );
  await tester.pump();
}

void _expectDocked(
  Rect rect,
  Size viewport,
  RemoteCommandBarEdge edge,
  double fraction,
) {
  const epsilon = 0.001;
  switch (edge) {
    case RemoteCommandBarEdge.top:
      expect(rect.top, closeTo(0, epsilon));
      expect(
        rect.left,
        closeTo((viewport.width - rect.width) * fraction, epsilon),
      );
    case RemoteCommandBarEdge.right:
      expect(rect.right, closeTo(viewport.width, epsilon));
      expect(
        rect.top,
        closeTo((viewport.height - rect.height) * fraction, epsilon),
      );
    case RemoteCommandBarEdge.bottom:
      expect(rect.bottom, closeTo(viewport.height, epsilon));
      expect(
        rect.left,
        closeTo((viewport.width - rect.width) * fraction, epsilon),
      );
    case RemoteCommandBarEdge.left:
      expect(rect.left, closeTo(0, epsilon));
      expect(
        rect.top,
        closeTo((viewport.height - rect.height) * fraction, epsilon),
      );
  }
}
