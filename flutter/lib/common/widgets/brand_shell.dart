import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/brand/portal_mark_spec.dart';

class CamelliaBrandMark extends StatelessWidget {
  const CamelliaBrandMark({
    super.key,
    this.size = 36,
    this.withPlate = true,
    this.monochrome = false,
    this.progress = 1,
    this.semanticLabel,
  });

  final double size;
  final bool withPlate;
  final bool monochrome;
  final double progress;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: semanticLabel,
      child: CustomPaint(
        size: Size.square(size),
        painter: _CamelliaBrandPainter(
          brightness: Theme.of(context).brightness,
          withPlate: withPlate,
          monochrome: monochrome,
          progress: progress,
        ),
      ),
    );
  }
}

class _CamelliaBrandPainter extends CustomPainter {
  const _CamelliaBrandPainter({
    required this.brightness,
    required this.withPlate,
    required this.monochrome,
    required this.progress,
  });

  final Brightness brightness;
  final bool withPlate;
  final bool monochrome;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    final origin = Offset((size.width - side) / 2, (size.height - side) / 2);
    final dark = brightness == Brightness.dark;
    final plate = dark
        ? CamelliaColors.portalPlateDark
        : CamelliaColors.portalPlateLight;
    final plateBorder = dark
        ? CamelliaColors.portalPlateBorderDark
        : CamelliaColors.portalPlateBorderLight;
    final ink = dark ? Colors.white : CamelliaColors.lightText;
    final easedProgress = Curves.easeOutCubic.transform(
      progress.clamp(0, 1).toDouble(),
    );

    if (withPlate) {
      final plateRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(origin.dx, origin.dy, side, side),
        Radius.circular(side * PortalMarkSpec.plateRadius),
      );
      canvas.drawRRect(plateRect, Paint()..color = plate);
      canvas.drawRRect(
        plateRect.deflate(math.max(1, side * 0.025)),
        Paint()
          ..color = plateBorder
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1, side * 0.025),
      );
    }

    final inset = withPlate ? side * PortalMarkSpec.contentInset : 0.0;
    final contentSide = side - inset * 2;
    final contentOrigin = origin + Offset(inset, inset);
    final spread = easedProgress;
    final rearOffset = Offset(
      (1 - spread) * contentSide * 0.10,
      (1 - spread) * contentSide * 0.10,
    );
    final frontOffset = -rearOffset;

    RRect scaledRect(PortalRectSpec spec, Offset animationOffset) {
      return RRect.fromRectAndRadius(
        Rect.fromLTWH(
          contentOrigin.dx + spec.left * contentSide + animationOffset.dx,
          contentOrigin.dy + spec.top * contentSide + animationOffset.dy,
          spec.width * contentSide,
          spec.height * contentSide,
        ),
        Radius.circular(spec.radius * contentSide),
      );
    }

    Paint gradientPaint(RRect rect, Color start, Color end) => Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [start, end],
      ).createShader(rect.outerRect)
      ..color = start.withValues(alpha: easedProgress);

    final rear = scaledRect(PortalMarkSpec.rearScreen, rearOffset);
    final rearCutout = scaledRect(PortalMarkSpec.rearCutout, rearOffset);
    final front = scaledRect(PortalMarkSpec.frontScreen, frontOffset);
    final frontCutout = scaledRect(PortalMarkSpec.frontCutout, frontOffset);
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRRect(rear),
        Path()..addRRect(rearCutout),
      ),
      monochrome
          ? (Paint()..color = ink.withValues(alpha: easedProgress))
          : gradientPaint(
              rear,
              CamelliaColors.portalBlue.withValues(alpha: easedProgress),
              CamelliaColors.aqua.withValues(alpha: easedProgress),
            ),
    );

    final connectorStart =
        contentOrigin +
        Offset(
          PortalMarkSpec.connectorStartX * contentSide,
          PortalMarkSpec.connectorStartY * contentSide,
        );
    final connectorEnd =
        contentOrigin +
        Offset(
          PortalMarkSpec.connectorEndX * contentSide,
          PortalMarkSpec.connectorEndY * contentSide,
        );
    canvas.drawLine(
      connectorStart,
      connectorEnd,
      Paint()
        ..shader = monochrome
            ? null
            : LinearGradient(
                colors: const [
                  CamelliaColors.portalGlow,
                  CamelliaColors.portalIndigo,
                ],
              ).createShader(Rect.fromPoints(connectorStart, connectorEnd))
        ..color = monochrome
            ? ink.withValues(alpha: easedProgress)
            : CamelliaColors.portalGlow.withValues(alpha: easedProgress)
        ..strokeWidth = contentSide * PortalMarkSpec.connectorWidth
        ..strokeCap = StrokeCap.round,
    );

    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRRect(front),
        Path()..addRRect(frontCutout),
      ),
      monochrome
          ? (Paint()..color = ink.withValues(alpha: easedProgress))
          : gradientPaint(
              front,
              CamelliaColors.portalIndigo.withValues(alpha: easedProgress),
              CamelliaColors.orchid.withValues(alpha: easedProgress),
            ),
    );
  }

  @override
  bool shouldRepaint(_CamelliaBrandPainter oldDelegate) =>
      oldDelegate.brightness != brightness ||
      oldDelegate.withPlate != withPlate ||
      oldDelegate.monochrome != monochrome ||
      oldDelegate.progress != progress;
}

class CamelliaAnimatedBrandMark extends StatelessWidget {
  const CamelliaAnimatedBrandMark({
    super.key,
    this.size = 42,
    this.withPlate = true,
    this.semanticLabel,
  });

  final double size;
  final bool withPlate;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
      builder: (context, progress, _) => CamelliaBrandMark(
        size: size,
        withPlate: withPlate,
        progress: progress,
        semanticLabel: semanticLabel,
      ),
    );
  }
}
