import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

const _lightPlate = (241, 246, 249);
const _lightPlateBorder = (196, 210, 219);
const _darkPlate = (24, 33, 45);
const _darkPlateBorder = (53, 69, 86);
const _amber = (243, 163, 58);
const _orange = (240, 128, 60);
const _coral = (237, 106, 82);
const _rose = (216, 78, 126);
const _ember = (227, 100, 72);
const _ivory = (240, 250, 252);
const _darkInk = (19, 37, 54);
const _bladeColors = [_amber, _orange, _coral, _rose, _ember];

image.ColorRgba8 _color((int, int, int) value, [int alpha = 255]) =>
    image.ColorRgba8(value.$1, value.$2, value.$3, alpha);

double _cubic(double a, double b, double c, double d, double t) {
  final mt = 1 - t;
  return mt * mt * mt * a +
      3 * mt * mt * t * b +
      3 * mt * t * t * c +
      t * t * t * d;
}

List<(double, double)> _blade(double radius) {
  const segments = 24;
  final points = <(double, double)>[];
  for (var index = 0; index <= segments; index++) {
    final t = index / segments;
    points.add((
      _cubic(-0.10, -0.36, -0.30, 0.18, t) * radius,
      _cubic(-0.04, -0.18, -0.66, -0.99, t) * radius,
    ));
  }
  for (var index = 1; index <= segments; index++) {
    final t = index / segments;
    points.add((
      _cubic(0.18, 0.36, 0.34, 0.10, t) * radius,
      _cubic(-0.99, -0.68, -0.30, -0.01, t) * radius,
    ));
  }
  for (var index = 1; index <= 8; index++) {
    final t = index / 8;
    points.add((
      ((1 - t) * (1 - t) * 0.10 - 0.10 * t * t) * radius,
      ((1 - t) * (1 - t) * -0.01 + 2 * (1 - t) * t * 0.08 - 0.04 * t * t) *
          radius,
    ));
  }
  return points;
}

List<image.Point> _rotatePoints(
  List<(double, double)> points, {
  required double angle,
  required double cx,
  required double cy,
}) {
  final cosine = math.cos(angle);
  final sine = math.sin(angle);
  return [
    for (final (x, y) in points)
      image.Point(cx + x * cosine - y * sine, cy + x * sine + y * cosine),
  ];
}

void _drawMark(
  image.Image target, {
  required double cx,
  required double cy,
  required double radius,
  bool monochrome = false,
  bool white = false,
  bool darkSurface = true,
}) {
  final mono = white ? (255, 255, 255) : (0, 0, 0);
  final blade = _blade(radius);
  for (var index = 0; index < 5; index++) {
    image.fillPolygon(
      target,
      vertices: _rotatePoints(
        blade,
        angle: index * math.pi * 2 / 5,
        cx: cx,
        cy: cy,
      ),
      color: _color(monochrome ? mono : _bladeColors[index]),
    );
  }
  final hub = (radius * 0.245).round();
  final aperture = (hub * 0.54).round();
  if (monochrome) {
    image.fillCircle(
      target,
      x: cx.round(),
      y: cy.round(),
      radius: hub,
      color: _color(mono),
      antialias: true,
    );
    _clearCircle(target, cx.round(), cy.round(), aperture);
  } else {
    image.fillCircle(
      target,
      x: cx.round(),
      y: cy.round(),
      radius: hub,
      color: _color(darkSurface ? _darkPlate : _lightPlate),
      antialias: true,
    );
    image.fillCircle(
      target,
      x: cx.round(),
      y: cy.round(),
      radius: aperture,
      color: _color(darkSurface ? _ivory : _darkInk),
      antialias: true,
    );
    final ringRadius = (hub * 1.12).round();
    final ringWidth = math.max(2, (radius * 0.025).round());
    for (var offset = 0; offset < ringWidth; offset++) {
      image.drawCircle(
        target,
        x: cx.round(),
        y: cy.round(),
        radius: ringRadius - offset,
        color: _color(_amber, 220),
        antialias: true,
      );
    }
  }
}

void _clearCircle(image.Image target, int cx, int cy, int radius) {
  final radiusSquared = radius * radius;
  for (var y = -radius; y <= radius; y++) {
    for (var x = -radius; x <= radius; x++) {
      if (x * x + y * y <= radiusSquared) {
        target.setPixelRgba(cx + x, cy + y, 0, 0, 0, 0);
      }
    }
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
    darkSurface: dark,
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
  final renderSize = size * 4;
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

const _markSvg =
    '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <rect width="1024" height="1024" rx="224" fill="#f1f6f9"/>
  <rect x="18" y="18" width="988" height="988" rx="206" fill="none" stroke="#c4d2db" stroke-width="12"/>
  <defs><path id="blade" d="M475 497C378 445 400 266 579 144C646 259 638 400 549 508Q512 542 475 497Z"/></defs>
  <use href="#blade" fill="#f3a33a"/><use href="#blade" fill="#f0803c" transform="rotate(72 512 512)"/><use href="#blade" fill="#ed6a52" transform="rotate(144 512 512)"/><use href="#blade" fill="#d84e7e" transform="rotate(216 512 512)"/><use href="#blade" fill="#e36448" transform="rotate(288 512 512)"/>
  <circle cx="512" cy="512" r="91" fill="#f1f6f9"/><circle cx="512" cy="512" r="49" fill="#132536"/>
  <circle cx="512" cy="512" r="102" fill="none" stroke="#f3a33a" stroke-width="10"/>
</svg>
''';

const _faviconSvg =
    '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <rect width="128" height="128" rx="28" fill="#f1f6f9"/>
  <g transform="scale(.125)"><defs><path id="b" d="M475 497C378 445 400 266 579 144C646 259 638 400 549 508Q512 542 475 497Z"/></defs><use href="#b" fill="#f3a33a"/><use href="#b" fill="#f0803c" transform="rotate(72 512 512)"/><use href="#b" fill="#ed6a52" transform="rotate(144 512 512)"/><use href="#b" fill="#d84e7e" transform="rotate(216 512 512)"/><use href="#b" fill="#e36448" transform="rotate(288 512 512)"/></g>
  <circle cx="64" cy="64" r="11.4" fill="#f1f6f9"/><circle cx="64" cy="64" r="6.1" fill="#132536"/>
  <circle cx="64" cy="64" r="12.75" fill="none" stroke="#f3a33a" stroke-width="1.25"/>
</svg>
''';

void _writeVectorAssets() {
  for (final path in [
    '../res/camellia-mark.svg',
    '../res/scalable.svg',
    'assets/icon.svg',
  ]) {
    File(path).writeAsStringSync(_markSvg);
  }
  File('web/favicon.svg').writeAsStringSync(_faviconSvg);
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
