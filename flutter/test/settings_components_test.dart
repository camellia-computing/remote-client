import 'package:camellia_remote_app/common/widgets/settings_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _settingsTheme = SettingsThemeData(
  settingsListBackground: Color(0xFFF6F7FB),
  settingsSectionBackground: Colors.white,
  dividerColor: Color(0xFFE0E3EB),
  tileHighlightColor: Color(0xFFE8ECFF),
  titleTextColor: Color(0xFF25283A),
  leadingIconsColor: Color(0xFF4D5FD0),
  trailingTextColor: Color(0xFF5F6475),
  tileDescriptionTextColor: Color(0xFF5F6475),
  settingsTileTextColor: Color(0xFF25283A),
  inactiveTitleColor: Color(0xFF9A9DAB),
  inactiveSubtitleColor: Color(0xFFAAADBA),
  inactiveSwitchColor: Color(0xFFAAADBA),
  titleTextStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
  tileTextStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
);

void main() {
  testWidgets('settings tiles expose full-row actions and stable targets', (
    tester,
  ) async {
    var switchValue = false;
    var actionCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsList(
            lightTheme: _settingsTheme,
            darkTheme: _settingsTheme,
            sections: [
              SettingsSection(
                title: const Text('Session'),
                tiles: [
                  SettingsTile.switchTile(
                    title: const Text('Show status'),
                    description: const Text('Expose connection health'),
                    leading: const Icon(Icons.monitor_heart_outlined),
                    initialValue: switchValue,
                    onToggle: (value) => switchValue = value,
                  ),
                  SettingsTile(
                    title: const Text('Open details'),
                    leading: const Icon(Icons.tune_rounded),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onPressed: (_) => actionCount++,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    final tiles = find.byType(ListTile);
    expect(tiles, findsNWidgets(2));
    expect(tester.getSize(tiles.first).height, greaterThanOrEqualTo(56));

    await tester.tap(find.text('Show status'));
    await tester.pump();
    expect(switchValue, isTrue);

    await tester.tap(find.text('Open details'));
    await tester.pump();
    expect(actionCount, 1);
  });

  testWidgets('disabled settings tile cannot invoke its action', (
    tester,
  ) async {
    var invoked = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsList(
            lightTheme: _settingsTheme,
            darkTheme: _settingsTheme,
            sections: [
              SettingsSection(
                tiles: [
                  SettingsTile(
                    title: const Text('Unavailable'),
                    enabled: false,
                    onPressed: (_) => invoked = true,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('Unavailable'));
    await tester.pump();
    expect(invoked, isFalse);
  });
}
