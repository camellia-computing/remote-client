import 'package:camellia_remote_app/desktop/widgets/material_mod_popup_menu.dart'
    as mod_menu;
import 'package:camellia_remote_app/desktop/widgets/popup_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('desktop command menu is bounded and has one action layer', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(460, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var selected = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Align(
              alignment: Alignment.topRight,
              child: FilledButton(
                onPressed: () {
                  mod_menu.showMenu<String>(
                    context: context,
                    position: const RelativeRect.fromLTRB(448, 20, 12, 780),
                    items:
                        MenuEntryButton<String>(
                          dismissOnClicked: true,
                          proc: () => selected = true,
                          childBuilder: (style) =>
                              Text('Connect', style: style),
                        ).build(
                          context,
                          const MenuConfig(
                            commonColor: Colors.blue,
                            height: CustomPopupMenuTheme.height,
                            dividerHeight: CustomPopupMenuTheme.dividerHeight,
                          ),
                        ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final menuItem = find.byType(mod_menu.PopupMenuItem<String>);
    expect(menuItem, findsOneWidget);
    expect(
      find.descendant(of: menuItem, matching: find.byType(TextButton)),
      findsNothing,
    );
    final menuSize = tester.getSize(find.byType(ListBody));
    expect(menuSize.width, inInclusiveRange(224, 320));
    expect(
      tester.getTopRight(find.byType(ListBody)).dx,
      lessThanOrEqualTo(448),
    );

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(selected, isTrue);
    expect(find.text('Connect'), findsNothing);
  });
}
