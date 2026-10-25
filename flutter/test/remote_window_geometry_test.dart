import 'dart:ui';

import 'package:camellia_remote_app/models/remote_window_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('landscape and portrait frames use their independent axes', () {
    const landscape = Rect.fromLTWH(0, 0, 1062, 607);
    const portrait = Rect.fromLTWH(0, 0, 607, 1062);

    expect(
      _contains(landscape, x: 500, y: 800),
      isFalse,
      reason: 'height must not inherit the landscape width',
    );
    expect(_contains(landscape, x: 500, y: 607), isTrue);
    expect(_contains(portrait, x: 800, y: 500), isFalse);
    expect(_contains(portrait, x: 607, y: 500), isTrue);
  });

  test('physical Windows frames are normalized on both axes', () {
    const physicalFrame = Rect.fromLTWH(0, 0, 2000, 1200);

    for (final ratio in [1.0, 1.25, 1.5, 2.0]) {
      final logicalWidth = physicalFrame.width / ratio;
      final logicalHeight = physicalFrame.height / ratio;
      expect(
        _contains(
          physicalFrame,
          x: logicalWidth,
          y: logicalHeight,
          ratio: ratio,
        ),
        isTrue,
        reason: 'DPR $ratio inclusive lower-right edge',
      );
      expect(
        _contains(
          physicalFrame,
          x: logicalWidth,
          y: logicalHeight + 0.001,
          ratio: ratio,
        ),
        isFalse,
        reason: 'DPR $ratio point below the real frame',
      );
      expect(
        _contains(
          physicalFrame,
          x: logicalWidth + 0.001,
          y: logicalHeight,
          ratio: ratio,
        ),
        isFalse,
        reason: 'DPR $ratio point right of the real frame',
      );
    }
  });

  test('logical non-Windows frames are not scaled a second time', () {
    const logicalFrame = Rect.fromLTWH(0, 0, 1000, 600);

    expect(
      _contains(
        logicalFrame,
        x: 900,
        y: 500,
        ratio: 2,
        frameUsesPhysicalPixels: false,
      ),
      isTrue,
    );
    expect(
      _contains(
        logicalFrame,
        x: 1000.001,
        y: 500,
        ratio: 2,
        frameUsesPhysicalPixels: false,
      ),
      isFalse,
    );
  });

  test('all edges are inclusive and points outside any edge are rejected', () {
    const frame = Rect.fromLTWH(0, 0, 320, 240);

    for (final point in [
      (x: 0.0, y: 0.0),
      (x: 320.0, y: 0.0),
      (x: 0.0, y: 240.0),
      (x: 320.0, y: 240.0),
    ]) {
      expect(_contains(frame, x: point.x, y: point.y), isTrue);
    }
    for (final point in [
      (x: -0.001, y: 10.0),
      (x: 320.001, y: 10.0),
      (x: 10.0, y: -0.001),
      (x: 10.0, y: 240.001),
    ]) {
      expect(_contains(frame, x: point.x, y: point.y), isFalse);
    }
  });

  test('invalid coordinates, frames, and physical scaling fail closed', () {
    const frame = Rect.fromLTWH(0, 0, 320, 240);

    expect(_contains(frame, x: double.nan, y: 0), isFalse);
    expect(_contains(frame, x: 0, y: double.infinity), isFalse);
    expect(_contains(const Rect.fromLTRB(0, 0, -1, 240), x: 0, y: 0), isFalse);
    expect(_contains(Rect.zero, x: 0, y: 0), isFalse);
    expect(
      _contains(const Rect.fromLTWH(0, 0, double.infinity, 240), x: 0, y: 0),
      isFalse,
    );
    expect(_contains(frame, x: 0, y: 0, ratio: 0), isFalse);
    expect(_contains(frame, x: 0, y: 0, ratio: double.nan), isFalse);
    expect(
      _contains(
        frame,
        x: 0,
        y: 0,
        ratio: double.nan,
        frameUsesPhysicalPixels: false,
      ),
      isTrue,
      reason: 'logical frames do not consume the physical DPR',
    );
  });
}

bool _contains(
  Rect frame, {
  required double x,
  required double y,
  double ratio = 1,
  bool frameUsesPhysicalPixels = true,
}) {
  return isLocalPointInsideWindowFrame(
    x: x,
    y: y,
    windowFrame: frame,
    devicePixelRatio: ratio,
    frameUsesPhysicalPixels: frameUsesPhysicalPixels,
  );
}
