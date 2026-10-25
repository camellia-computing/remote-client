import 'dart:ui';

/// Whether a window-local logical point belongs to [windowFrame].
///
/// Windows multi-window APIs report physical frame dimensions while Flutter
/// pointer events use logical coordinates. Other desktop implementations
/// already report logical frames, so applying the device-pixel ratio there
/// would shrink the valid input region a second time.
bool isLocalPointInsideWindowFrame({
  required double x,
  required double y,
  required Rect windowFrame,
  required double devicePixelRatio,
  required bool frameUsesPhysicalPixels,
}) {
  if (!x.isFinite ||
      !y.isFinite ||
      !windowFrame.width.isFinite ||
      !windowFrame.height.isFinite ||
      windowFrame.width <= 0 ||
      windowFrame.height <= 0) {
    return false;
  }

  var width = windowFrame.width;
  var height = windowFrame.height;
  if (frameUsesPhysicalPixels) {
    if (!devicePixelRatio.isFinite || devicePixelRatio <= 0) {
      return false;
    }
    width /= devicePixelRatio;
    height /= devicePixelRatio;
  }

  return x >= 0 && y >= 0 && x <= width && y <= height;
}
