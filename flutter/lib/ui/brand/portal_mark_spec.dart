/// Geometry shared by the runtime painter and the asset generator.
///
/// Values are normalized to a 1 x 1 canvas so every platform artifact is
/// derived from the same source instead of maintaining a second SVG drawing.
final class PortalRectSpec {
  const PortalRectSpec(
    this.left,
    this.top,
    this.width,
    this.height,
    this.radius,
  );

  final double left;
  final double top;
  final double width;
  final double height;
  final double radius;
}

abstract final class PortalMarkSpec {
  static const rearScreen = PortalRectSpec(0.08, 0.12, 0.58, 0.50, 0.15);
  static const rearCutout = PortalRectSpec(0.17, 0.21, 0.40, 0.32, 0.09);
  static const frontScreen = PortalRectSpec(0.34, 0.38, 0.58, 0.50, 0.15);
  static const frontCutout = PortalRectSpec(0.43, 0.47, 0.40, 0.32, 0.09);

  static const connectorStartX = 0.43;
  static const connectorStartY = 0.42;
  static const connectorEndX = 0.57;
  static const connectorEndY = 0.58;
  static const connectorWidth = 0.12;

  static const plateRadius = 0.23;
  static const contentInset = 0.12;

  static int _canvasValue(double value) => (value * 1024).round();

  static String _svgRect(PortalRectSpec spec, {required String fill}) {
    final contentSide = 1 - contentInset * 2;
    final left = contentInset + spec.left * contentSide;
    final top = contentInset + spec.top * contentSide;
    return '<rect x="${_canvasValue(left)}" y="${_canvasValue(top)}" '
        'width="${_canvasValue(spec.width * contentSide)}" '
        'height="${_canvasValue(spec.height * contentSide)}" '
        'rx="${_canvasValue(spec.radius * contentSide)}" fill="$fill"/>';
  }

  static String svg({bool monochrome = false}) {
    final rear = monochrome ? '#ffffff' : '#1ba7ff';
    final front = monochrome ? '#ffffff' : '#6558f5';
    final connector = monochrome ? '#ffffff' : '#ff5c7a';
    final contentSide = 1 - contentInset * 2;
    final connectorStartX = _canvasValue(
      contentInset + PortalMarkSpec.connectorStartX * contentSide,
    );
    final connectorStartY = _canvasValue(
      contentInset + PortalMarkSpec.connectorStartY * contentSide,
    );
    final connectorEndX = _canvasValue(
      contentInset + PortalMarkSpec.connectorEndX * contentSide,
    );
    final connectorEndY = _canvasValue(
      contentInset + PortalMarkSpec.connectorEndY * contentSide,
    );
    return '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="plate" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#f7f8ff"/><stop offset="1" stop-color="#e9edff"/></linearGradient>
    <linearGradient id="rear" x1="0" y1="0" x2="1" y2="1"><stop stop-color="$rear"/><stop offset="1" stop-color="${monochrome ? rear : '#19bfa9'}"/></linearGradient>
    <linearGradient id="front" x1="0" y1="0" x2="1" y2="1"><stop stop-color="$front"/><stop offset="1" stop-color="${monochrome ? front : '#8c63f7'}"/></linearGradient>
    <mask id="rear-mask">${_svgRect(rearScreen, fill: '#ffffff')}${_svgRect(rearCutout, fill: '#000000')}</mask>
    <mask id="front-mask">${_svgRect(frontScreen, fill: '#ffffff')}${_svgRect(frontCutout, fill: '#000000')}</mask>
  </defs>
  <rect width="1024" height="1024" rx="${_canvasValue(plateRadius)}" fill="${monochrome ? 'none' : 'url(#plate)'}"/>
  ${_svgRect(rearScreen, fill: 'url(#rear)').replaceFirst('/>', ' mask="url(#rear-mask)"/>')}
  <path d="M$connectorStartX $connectorStartY L$connectorEndX $connectorEndY" stroke="$connector" stroke-width="${_canvasValue(connectorWidth * contentSide)}" stroke-linecap="round"/>
  ${_svgRect(frontScreen, fill: 'url(#front)').replaceFirst('/>', ' mask="url(#front-mask)"/>')}
</svg>''';
  }
}
