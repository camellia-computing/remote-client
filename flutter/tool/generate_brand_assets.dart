import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:camellia_remote_app/ui/brand/portal_mark_spec.dart';

const _lightPlate = (243, 245, 255);
const _lightPlateBorder = (217, 221, 242);
const _darkPlate = (18, 21, 34);
const _darkPlateBorder = (52, 57, 81);
const _blue = (27, 167, 255);
const _indigo = (101, 88, 245);
const _coral = (255, 92, 122);

image.ColorRgba8 _color((int, int, int) value, [int alpha = 255]) =>
    image.ColorRgba8(value.$1, value.$2, value.$3, alpha);

({int x1, int y1, int x2, int y2, int radius}) _scaledRect(
  PortalRectSpec spec,
  double left,
  double top,
  double side,
) => (
  x1: (left + spec.left * side).round(),
  y1: (top + spec.top * side).round(),
  x2: (left + (spec.left + spec.width) * side).round(),
  y2: (top + (spec.top + spec.height) * side).round(),
  radius: (spec.radius * side).round(),
);

void _fillRounded(
  image.Image target,
  ({int x1, int y1, int x2, int y2, int radius}) rect,
  image.Color color,
) {
  image.fillRect(
    target,
    x1: rect.x1,
    y1: rect.y1,
    x2: rect.x2,
    y2: rect.y2,
    radius: rect.radius,
    color: color,
  );
}

void _clearRounded(
  image.Image target,
  ({int x1, int y1, int x2, int y2, int radius}) rect,
) {
  final radius = rect.radius.toDouble();
  final left = rect.x1.toDouble();
  final top = rect.y1.toDouble();
  final right = rect.x2.toDouble();
  final bottom = rect.y2.toDouble();
  final innerLeft = left + radius;
  final innerRight = right - radius;
  final innerTop = top + radius;
  final innerBottom = bottom - radius;
  final transparent = image.ColorRgba8(0, 0, 0, 0);

  final pixels = target.getRange(
    rect.x1,
    rect.y1,
    rect.x2 - rect.x1 + 1,
    rect.y2 - rect.y1 + 1,
  );
  while (pixels.moveNext()) {
    final pixel = pixels.current;
    final x = pixel.x + 0.5;
    final y = pixel.y + 0.5;
    final nearestX = x.clamp(innerLeft, innerRight);
    final nearestY = y.clamp(innerTop, innerBottom);
    final dx = x - nearestX;
    final dy = y - nearestY;
    if (dx * dx + dy * dy <= radius * radius) {
      pixel.set(transparent);
    }
  }
}

void _drawThickLine(
  image.Image target, {
  required double x1,
  required double y1,
  required double x2,
  required double y2,
  required int width,
  required image.Color color,
}) {
  final dx = x2 - x1;
  final dy = y2 - y1;
  final length = math.sqrt(dx * dx + dy * dy);
  final halfWidth = width / 2;
  final offsetX = -dy / length * halfWidth;
  final offsetY = dx / length * halfWidth;
  image.fillPolygon(
    target,
    vertices: [
      image.Point((x1 + offsetX).round(), (y1 + offsetY).round()),
      image.Point((x2 + offsetX).round(), (y2 + offsetY).round()),
      image.Point((x2 - offsetX).round(), (y2 - offsetY).round()),
      image.Point((x1 - offsetX).round(), (y1 - offsetY).round()),
    ],
    color: color,
  );
  for (final point in [(x1, y1), (x2, y2)]) {
    image.fillCircle(
      target,
      x: point.$1.round(),
      y: point.$2.round(),
      radius: width ~/ 2,
      color: color,
      antialias: false,
    );
  }
}

void _drawMark(
  image.Image target, {
  required double cx,
  required double cy,
  required double radius,
  bool monochrome = false,
  bool white = false,
  (int, int, int)? cutoutColor,
}) {
  final side = radius * 2;
  final left = cx - radius;
  final top = cy - radius;
  final mono = white ? (255, 255, 255) : (14, 17, 28);
  final rear = _scaledRect(PortalMarkSpec.rearScreen, left, top, side);
  final rearCutout = _scaledRect(PortalMarkSpec.rearCutout, left, top, side);
  final front = _scaledRect(PortalMarkSpec.frontScreen, left, top, side);
  final frontCutout = _scaledRect(PortalMarkSpec.frontCutout, left, top, side);
  _fillRounded(target, rear, _color(monochrome ? mono : _blue));
  if (cutoutColor == null) {
    _clearRounded(target, rearCutout);
  } else {
    _fillRounded(target, rearCutout, _color(cutoutColor));
  }
  _drawThickLine(
    target,
    x1: left + PortalMarkSpec.connectorStartX * side,
    y1: top + PortalMarkSpec.connectorStartY * side,
    x2: left + PortalMarkSpec.connectorEndX * side,
    y2: top + PortalMarkSpec.connectorEndY * side,
    width: (PortalMarkSpec.connectorWidth * side).round(),
    color: _color(monochrome ? mono : _coral),
  );
  _fillRounded(target, front, _color(monochrome ? mono : _indigo));
  if (cutoutColor == null) {
    _clearRounded(target, frontCutout);
  } else {
    _fillRounded(target, frontCutout, _color(cutoutColor));
  }
}

image.Image _renderAppIcon(
  int size, {
  bool transparentCorners = false,
  bool dark = false,
}) {
  final renderSize = size * 2;
  final icon = image.Image(
    width: renderSize,
    height: renderSize,
    numChannels: 4,
  );
  final scale = renderSize / 1024;
  final margin = transparentCorners ? (30 * scale).round() : 0;
  image.fillRect(
    icon,
    x1: margin,
    y1: margin,
    x2: renderSize - margin - 1,
    y2: renderSize - margin - 1,
    radius: (224 * scale).round(),
    color: _color(dark ? _darkPlate : _lightPlate),
  );
  image.drawRect(
    icon,
    x1: margin + (10 * scale).round(),
    y1: margin + (10 * scale).round(),
    x2: renderSize - margin - 1 - (10 * scale).round(),
    y2: renderSize - margin - 1 - (10 * scale).round(),
    radius: (214 * scale).round(),
    color: _color(dark ? _darkPlateBorder : _lightPlateBorder, 220),
    thickness: math.max(2, (4 * scale).round()),
  );
  _drawMark(
    icon,
    cx: renderSize / 2,
    cy: renderSize / 2,
    radius: 372 * scale,
    cutoutColor: dark ? _darkPlate : _lightPlate,
  );
  return image.copyResize(
    icon,
    width: size,
    height: size,
    interpolation: image.Interpolation.cubic,
  );
}

image.Image _renderMark(
  int size, {
  bool monochrome = false,
  bool white = false,
  bool colored = true,
}) {
  final renderSize = size * 2;
  final icon = image.Image(
    width: renderSize,
    height: renderSize,
    numChannels: 4,
  );
  _drawMark(
    icon,
    cx: renderSize / 2,
    cy: renderSize / 2,
    radius: renderSize * 0.49,
    monochrome: monochrome || !colored,
    white: white,
  );
  return image.copyResize(
    icon,
    width: size,
    height: size,
    interpolation: image.Interpolation.cubic,
  );
}

void _writePng(String path, image.Image value) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(image.encodePng(value));
}

void _writeIco(String path, image.Image source, List<int> sizes) {
  final document = image.copyResize(
    source,
    width: sizes.first,
    height: sizes.first,
    interpolation: image.Interpolation.cubic,
  );
  for (final size in sizes.skip(1)) {
    document.addFrame(
      image.copyResize(
        source,
        width: size,
        height: size,
        interpolation: image.Interpolation.cubic,
      ),
    );
  }
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(image.encodeIco(document));
}

Uint8List _uint32(int value) {
  final data = ByteData(4)..setUint32(0, value, Endian.big);
  return data.buffer.asUint8List();
}

void _writeIcns(String path, image.Image source) {
  final chunks = <(String, int)>[
    ('icp4', 16),
    ('icp5', 32),
    ('icp6', 64),
    ('ic07', 128),
    ('ic08', 256),
    ('ic09', 512),
    ('ic10', 1024),
    ('ic11', 32),
    ('ic12', 64),
    ('ic13', 256),
    ('ic14', 512),
  ];
  final encoded = <(String, Uint8List)>[
    for (final (type, size) in chunks)
      (
        type,
        Uint8List.fromList(
          image.encodePng(
            image.copyResize(
              source,
              width: size,
              height: size,
              interpolation: image.Interpolation.cubic,
            ),
          ),
        ),
      ),
  ];
  final totalLength =
      8 + encoded.fold<int>(0, (sum, entry) => sum + 8 + entry.$2.length);
  final output = BytesBuilder(copy: false)
    ..add('icns'.codeUnits)
    ..add(_uint32(totalLength));
  for (final (type, bytes) in encoded) {
    output
      ..add(type.codeUnits)
      ..add(_uint32(bytes.length + 8))
      ..add(bytes);
  }
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(output.takeBytes());
}

void _writeVectorAssets() {
  final markSvg = PortalMarkSpec.svg();
  for (final path in [
    '../res/camellia-mark.svg',
    '../res/scalable.svg',
    'assets/icon.svg',
  ]) {
    File(path).writeAsStringSync(markSvg);
  }
  File('web/favicon.svg').writeAsStringSync(markSvg);
}

void _writeAppleIconSet(String directory, image.Image source) {
  final manifestFile = File('$directory/Contents.json');
  if (!manifestFile.existsSync()) return;
  final manifest = jsonDecode(manifestFile.readAsStringSync());
  for (final entry in manifest['images'] as List<dynamic>) {
    if (entry is! Map<String, dynamic>) continue;
    final filename = entry['filename'];
    final logicalSize = entry['size'];
    final scaleText = entry['scale'];
    if (filename is! String || logicalSize is! String || scaleText is! String) {
      continue;
    }
    final points = double.tryParse(logicalSize.split('x').first);
    final scale = double.tryParse(scaleText.replaceAll('x', ''));
    if (points == null || scale == null) continue;
    final pixels = (points * scale).round();
    _writePng(
      '$directory/$filename',
      image.copyResize(
        source,
        width: pixels,
        height: pixels,
        interpolation: image.Interpolation.cubic,
      ),
    );
  }
}

void main() {
  final app = _renderAppIcon(1024);
  final darkApp = _renderAppIcon(1024, dark: true);
  final mac = _renderAppIcon(1024, transparentCorners: true);
  _writePng('../res/icon.png', app);
  _writePng('../res/mac-icon.png', mac);
  _writePng('../res/android-foreground.png', _renderMark(1024));
  _writePng(
    '../res/android-monochrome.png',
    _renderMark(1024, monochrome: true, white: true),
  );
  _writeIco('../res/icon.ico', app, [16, 20, 24, 32, 40, 48, 64, 128, 256]);
  _writeIco('windows/runner/resources/app_icon.ico', app, [
    16,
    20,
    24,
    32,
    40,
    48,
    64,
    128,
    256,
  ]);
  _writeIcns('macos/Runner/AppIcon.icns', mac);
  _writeAppleIconSet('ios/Runner/Assets.xcassets/AppIcon.appiconset', app);

  for (final size in [32, 64, 128]) {
    _writePng(
      '../res/${size}x$size.png',
      image.copyResize(app, width: size, height: size),
    );
  }
  _writePng('../res/128x128@2x.png', image.copyResize(app, width: 256));

  final tray = _renderMark(256);
  _writeIco('../res/tray-icon.ico', tray, [
    16,
    20,
    24,
    32,
    40,
    48,
    64,
    128,
    256,
  ]);
  _writePng('../res/mac-tray-dark-x2.png', _renderMark(36, monochrome: true));
  _writePng(
    '../res/mac-tray-light-x2.png',
    _renderMark(36, monochrome: true, white: true),
  );
  const androidDensities = {
    'mdpi': 24,
    'hdpi': 36,
    'xhdpi': 48,
    'xxhdpi': 72,
    'xxxhdpi': 96,
  };
  for (final entry in androidDensities.entries) {
    _writePng(
      'android/app/src/main/res/mipmap-${entry.key}/ic_stat_logo.png',
      _renderMark(entry.value, monochrome: true, white: true),
    );
  }
  const androidLegacyLauncherDensities = {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };
  for (final entry in androidLegacyLauncherDensities.entries) {
    _writePng(
      'android/app/src/main/res/mipmap-${entry.key}/ic_launcher.png',
      image.copyResize(
        app,
        width: entry.value,
        height: entry.value,
        interpolation: image.Interpolation.cubic,
      ),
    );
  }
  const androidLauncherDensities = {
    'mdpi': 108,
    'hdpi': 162,
    'xhdpi': 216,
    'xxhdpi': 324,
    'xxxhdpi': 432,
  };
  for (final entry in androidLauncherDensities.entries) {
    final directory = 'android/app/src/main/res/drawable-${entry.key}';
    _writePng(
      '$directory/ic_launcher_foreground.png',
      _renderMark(entry.value),
    );
    _writePng(
      '$directory/ic_launcher_monochrome.png',
      _renderMark(entry.value, monochrome: true, white: true),
    );
  }
  _writePng('assets/brand-mark.png', app);
  _writePng('assets/brand-mark-dark.png', darkApp);
  _writePng('web/favicon.png', image.copyResize(app, width: 32, height: 32));
  for (final size in [192, 512]) {
    final icon = image.copyResize(app, width: size, height: size);
    _writePng('web/icons/Icon-$size.png', icon);
    _writePng('web/icons/Icon-maskable-$size.png', icon);
  }
  _writeVectorAssets();
}
