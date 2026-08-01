import 'package:camellia_remote_app/ui/remote_ui_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('command bar tiers preserve the canvas at every dock extent', () {
    expect(RemoteCommandBarTier.forExtent(320), RemoteCommandBarTier.core);
    expect(RemoteCommandBarTier.forExtent(419), RemoteCommandBarTier.core);
    expect(RemoteCommandBarTier.forExtent(420), RemoteCommandBarTier.input);
    expect(
      RemoteCommandBarTier.forExtent(560),
      RemoteCommandBarTier.collaboration,
    );
    expect(RemoteCommandBarTier.forExtent(720), RemoteCommandBarTier.full);
    expect(
      RemoteCommandBarTier.forExtent(double.infinity),
      RemoteCommandBarTier.full,
    );
    expect(
      RemoteCommandBarTier.collaboration.includes(RemoteCommandBarTier.input),
      isTrue,
    );
    expect(
      RemoteCommandBarTier.input.includes(RemoteCommandBarTier.full),
      isFalse,
    );
  });

  group('RemoteCommandBarPreferences', () {
    test('round-trips every dock edge', () {
      for (final edge in RemoteCommandBarEdge.values) {
        final source = RemoteCommandBarPreferences(edge: edge, fraction: 0.27);
        expect(RemoteCommandBarPreferences.decode(source.encode()), source);
        expect(
          edge.isHorizontal,
          edge == RemoteCommandBarEdge.top ||
              edge == RemoteCommandBarEdge.bottom,
        );
      }
    });

    test('normalizes fractions before persistence', () {
      expect(
        const RemoteCommandBarPreferences(fraction: -2).normalized().fraction,
        0,
      );
      expect(
        const RemoteCommandBarPreferences(fraction: 8).normalized().fraction,
        1,
      );
      expect(
        const RemoteCommandBarPreferences(
          fraction: double.nan,
        ).normalized().fraction,
        0.5,
      );
    });

    test('fails closed for malformed or unsupported state', () {
      for (final source in <String?>[
        null,
        '',
        '{',
        '[]',
        '{"version":2,"edge":"left","fraction":0.2}',
      ]) {
        expect(
          RemoteCommandBarPreferences.decode(source),
          RemoteCommandBarPreferences.defaults,
        );
      }
    });

    test('uses safe defaults for unknown fields', () {
      expect(
        RemoteCommandBarPreferences.decode(
          '{"version":1,"edge":"future","fraction":"bad"}',
        ),
        RemoteCommandBarPreferences.defaults,
      );
    });
  });

  test('session status formats missing values and units consistently', () {
    const status = SessionStatusSnapshot(
      delay: ' 42 ',
      targetBitrate: '900',
      codec: '  AV1 ',
    );

    expect(status.delayValue, '42 ms');
    expect(status.bitrateValue, '900 kbps');
    expect(status.display(status.codec), 'AV1');
    expect(status.display('  '), '—');
    expect(const SessionStatusSnapshot().delayValue, '—');
    expect(const SessionStatusSnapshot().bitrateValue, '—');
    expect(const SessionStatusSnapshot(delay: '42 ms').delayValue, '42 ms');
    expect(
      const SessionStatusSnapshot(targetBitrate: '900 KBPS').bitrateValue,
      '900 KBPS',
    );
  });
}
