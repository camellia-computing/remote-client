import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/device_workspace_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('device controls choose stable responsive layouts', () {
    expect(deviceCategoryLayoutForWidth(390), DeviceCategoryLayout.dropdown);
    expect(deviceCategoryLayoutForWidth(519), DeviceCategoryLayout.dropdown);
    expect(deviceCategoryLayoutForWidth(520), DeviceCategoryLayout.wrapped);
    expect(deviceActionLayoutForWidth(390), DeviceActionLayout.stacked);
    expect(deviceActionLayoutForWidth(440), DeviceActionLayout.twoRows);
    expect(deviceActionLayoutForWidth(639), DeviceActionLayout.twoRows);
    expect(deviceActionLayoutForWidth(640), DeviceActionLayout.inline);
  });

  test('desktop search width is bounded without consuming the action row', () {
    expect(deviceSearchWidth(390), 390);
    expect(deviceSearchWidth(440), 220);
    expect(deviceSearchWidth(1024), 320);
    expect(deviceSearchWidth(1280), 320);
  });

  testWidgets('option menu uses one compact selectable row contract', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: CamelliaTheme.build(
          brightness: Brightness.light,
          desktopDensity: true,
        ),
        home: Scaffold(
          body: Center(
            child: DeviceOptionMenuButton<String>(
              tooltip: 'Change view',
              icon: Icons.grid_view_rounded,
              selectedValue: 'grid',
              options: const [
                DeviceOptionMenuItem(
                  value: 'grid',
                  label: 'Big tiles',
                  icon: Icons.grid_view_rounded,
                ),
                DeviceOptionMenuItem(
                  value: 'list',
                  label: 'List',
                  icon: Icons.view_list_rounded,
                ),
              ],
              onSelected: (value) => selected = value,
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(PopupMenuButton<String>)),
      const Size(44, 44),
    );
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('Big tiles'), findsOneWidget);
    expect(find.text('List'), findsOneWidget);
    expect(find.text('Change view'), findsNothing);
    await tester.tap(find.text('List'));
    await tester.pumpAndSettle();
    expect(selected, 'list');
  });
}
