import 'package:camellia_remote_app/ui/brand/portal_mark_spec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('portal geometry stays inside its normalized canvas', () {
    for (final rect in [
      PortalMarkSpec.rearScreen,
      PortalMarkSpec.rearCutout,
      PortalMarkSpec.frontScreen,
      PortalMarkSpec.frontCutout,
    ]) {
      expect(rect.left, inInclusiveRange(0, 1));
      expect(rect.top, inInclusiveRange(0, 1));
      expect(rect.width, greaterThan(0));
      expect(rect.height, greaterThan(0));
      expect(rect.left + rect.width, lessThanOrEqualTo(1));
      expect(rect.top + rect.height, lessThanOrEqualTo(1));
      expect(rect.radius, greaterThan(0));
    }
  });

  test('screen cutouts remain contained by their frames', () {
    void expectContained(PortalRectSpec outer, PortalRectSpec inner) {
      expect(inner.left, greaterThan(outer.left));
      expect(inner.top, greaterThan(outer.top));
      expect(inner.left + inner.width, lessThan(outer.left + outer.width));
      expect(inner.top + inner.height, lessThan(outer.top + outer.height));
    }

    expectContained(PortalMarkSpec.rearScreen, PortalMarkSpec.rearCutout);
    expectContained(PortalMarkSpec.frontScreen, PortalMarkSpec.frontCutout);
  });

  test('vector export contains the reviewed portal layers', () {
    final colored = PortalMarkSpec.svg();
    final monochrome = PortalMarkSpec.svg(monochrome: true);

    expect(colored, contains('viewBox="0 0 1024 1024"'));
    expect(colored, contains('#1ba7ff'));
    expect(colored, contains('#6558f5'));
    expect(colored, contains('#ff5c7a'));
    expect(monochrome, isNot(contains('#1ba7ff')));
    expect(monochrome, contains('stroke="#ffffff"'));
  });
}
