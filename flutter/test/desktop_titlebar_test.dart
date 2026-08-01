import 'package:camellia_remote_app/desktop/widgets/titlebar_widget.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeWindowController implements DesktopWindowController {
  bool maximized = false;
  int dragCount = 0;
  int menuCount = 0;
  int minimizeCount = 0;
  int closeCount = 0;

  @override
  Future<void> close() async => closeCount++;

  @override
  Future<bool> isMaximized() async => maximized;

  @override
  Future<void> maximize() async => maximized = true;

  @override
  Future<void> minimize() async => minimizeCount++;

  @override
  Future<void> showSystemMenu() async => menuCount++;

  @override
  Future<void> startDragging() async => dragCount++;

  @override
  Future<void> unmaximize() async => maximized = false;
}

Widget _app(_FakeWindowController controller) => MaterialApp(
  home: Scaffold(
    body: Column(
      children: [
        DesktopTitleBar(
          appName: 'Remote fixture',
          controller: controller,
          showCaptionButtons: true,
        ),
        const Expanded(child: SizedBox()),
      ],
    ),
  ),
);

void main() {
  testWidgets('title bar exposes standard caption actions', (tester) async {
    final controller = _FakeWindowController();
    await tester.pumpWidget(_app(controller));

    expect(find.text('Remote fixture'), findsOneWidget);
    await tester.tap(find.byTooltip('Minimize'));
    await tester.tap(find.byTooltip('Maximize'));
    await tester.pump();

    expect(controller.minimizeCount, 1);
    expect(controller.maximized, isTrue);
    expect(find.byTooltip('Restore'), findsOneWidget);

    await tester.tap(find.byTooltip('Restore'));
    await tester.tap(find.byTooltip('Close'));
    expect(controller.maximized, isFalse);
    expect(controller.closeCount, 1);
  });

  testWidgets('drag region moves, toggles, and opens the system menu', (
    tester,
  ) async {
    final controller = _FakeWindowController();
    await tester.pumpWidget(_app(controller));
    final dragRegion = find.byKey(const ValueKey('desktop-title-drag-region'));

    await tester.tap(dragRegion);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(dragRegion);
    await tester.pump();
    expect(controller.maximized, isTrue);

    await tester.pump(const Duration(milliseconds: 400));
    await tester.drag(dragRegion, const Offset(30, 0));
    expect(controller.dragCount, 1);

    await tester.tap(dragRegion, buttons: kSecondaryMouseButton);
    expect(controller.menuCount, 1);
    await tester.pump(const Duration(milliseconds: 400));
  });
}
