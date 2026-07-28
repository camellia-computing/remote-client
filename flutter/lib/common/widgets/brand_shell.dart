import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';

class CamelliaBrandMark extends StatelessWidget {
  const CamelliaBrandMark({
    super.key,
    this.size = 36,
    this.withPlate = true,
    this.monochrome = false,
    this.progress = 1,
  });

  final double size;
  final bool withPlate;
  final bool monochrome;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: 'Camellia',
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
        ? CamelliaColors.brandPlateDark
        : CamelliaColors.brandPlateLight;
    final plateBorder = dark
        ? CamelliaColors.brandPlateBorderDark
        : CamelliaColors.brandPlateBorderLight;
    final ink = monochrome
        ? (dark ? Colors.white : CamelliaColors.lightText)
        : (withPlate ? const Color(0xFFF7F8FA) : plate);
    final easedProgress = Curves.easeOutCubic.transform(
      progress.clamp(0, 1).toDouble(),
    );

    if (withPlate) {
      final plateRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(origin.dx, origin.dy, side, side),
        Radius.circular(side * 0.24),
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

    final inset = withPlate ? side * 0.13 : 0.0;
    final radius = (side - inset * 2) / 2;
    final center = Offset(origin.dx + side / 2, origin.dy + side / 2);
    final blade = _bladePath(radius);
    const bladeColors = [
      CamelliaColors.brandAmber,
      CamelliaColors.brandEmber,
      CamelliaColors.brandFlame,
      CamelliaColors.brandRose,
      CamelliaColors.brandCoral,
    ];

    for (var index = 0; index < bladeColors.length; index++) {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(
        index * math.pi * 2 / bladeColors.length - (1 - easedProgress) * 0.42,
      );
      final scale = 0.78 + easedProgress * 0.22;
      canvas.scale(scale, scale);
      canvas.drawPath(
        blade,
        Paint()
          ..color = (monochrome ? ink : bladeColors[index]).withValues(
            alpha: easedProgress * (monochrome ? 1 : 0.94),
          )
          ..style = PaintingStyle.fill,
      );
      canvas.restore();
    }

    final hubRadius = radius * 0.245 * easedProgress;
    canvas.drawCircle(
      center,
      hubRadius,
      Paint()..color = monochrome ? ink : plate,
    );
    canvas.drawCircle(
      center,
      hubRadius * 0.54,
      Paint()
        ..color = monochrome
            ? plate.withValues(alpha: withPlate ? 1 : 0)
            : dark
            ? CamelliaColors.brandHubDark
            : CamelliaColors.brandHubLight,
    );
    if (!monochrome) {
      canvas.drawCircle(
        center,
        hubRadius * 1.12,
        Paint()
          ..color = bladeColors.first.withValues(alpha: 0.82 * easedProgress)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1, radius * 0.025),
      );
    }
  }

  Path _bladePath(double radius) {
    return Path()
      ..moveTo(-radius * 0.10, -radius * 0.04)
      ..cubicTo(
        -radius * 0.36,
        -radius * 0.18,
        -radius * 0.30,
        -radius * 0.66,
        radius * 0.18,
        -radius * 0.99,
      )
      ..cubicTo(
        radius * 0.36,
        -radius * 0.68,
        radius * 0.34,
        -radius * 0.30,
        radius * 0.10,
        -radius * 0.01,
      )
      ..quadraticBezierTo(0, radius * 0.08, -radius * 0.10, -radius * 0.04)
      ..close();
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
  });

  final double size;
  final bool withPlate;

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
      ),
    );
  }
}

class CamelliaWordmark extends StatelessWidget {
  const CamelliaWordmark({super.key, this.compact = false, this.subtitle});

  final bool compact;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CamelliaAnimatedBrandMark(size: compact ? 30 : 38),
        if (!compact) ...[
          const SizedBox(width: 11),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Camellia',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    letterSpacing: 0,
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class CamelliaAccountButton extends StatelessWidget {
  const CamelliaAccountButton({
    super.key,
    required this.label,
    required this.detail,
    required this.statusColor,
    required this.onPressed,
    this.avatarUrl = '',
    this.statusIcon = Icons.circle_rounded,
    this.busy = false,
    this.compact = false,
  });

  final String label;
  final String detail;
  final String avatarUrl;
  final Color statusColor;
  final IconData statusIcon;
  final bool busy;
  final bool compact;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final normalizedLabel = label.trim().isEmpty ? '?' : label.trim();
    final initial = String.fromCharCode(normalizedLabel.runes.first);
    final avatar = Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          clipBehavior: Clip.antiAlias,
          child: avatarUrl.trim().isEmpty
              ? Text(
                  initial.toUpperCase(),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                )
              : Image.network(
                  avatarUrl,
                  width: 34,
                  height: 34,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Text(
                    initial.toUpperCase(),
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
        ),
        Positioned(
          right: -1,
          bottom: -1,
          child: Container(
            width: 12,
            height: 12,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              shape: BoxShape.circle,
            ),
            child: busy
                ? SizedBox(
                    width: 8,
                    height: 8,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.4,
                      color: statusColor,
                    ),
                  )
                : Icon(statusIcon, size: 9, color: statusColor),
          ),
        ),
      ],
    );
    return Tooltip(
      message: detail.isEmpty ? label : '$label\n$detail',
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CamelliaRadius.surface),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Container(
            constraints: BoxConstraints(
              minHeight: 44,
              minWidth: compact ? 52 : 0,
              maxWidth: compact ? 52 : 220,
            ),
            padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                avatar,
                if (!compact) ...[
                  const SizedBox(width: 9),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge,
                        ),
                        if (detail.isNotEmpty)
                          Text(
                            detail,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.expand_more_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CamelliaNavigationRail extends StatelessWidget {
  const CamelliaNavigationRail({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.extended = false,
    this.footer,
  });

  final List<NavigationDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final bool extended;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: extended ? 232 : 80,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          right: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: SafeArea(
        right: false,
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                extended ? 18 : 21,
                18,
                extended ? 18 : 21,
                24,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: CamelliaWordmark(compact: !extended),
              ),
            ),
            for (var index = 0; index < destinations.length; index++)
              _RailDestination(
                destination: destinations[index],
                selected: selectedIndex == index,
                extended: extended,
                onTap: () => onDestinationSelected(index),
              ),
            const Spacer(),
            if (footer != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                child: footer,
              ),
          ],
        ),
      ),
    );
  }
}

class _RailDestination extends StatelessWidget {
  const _RailDestination({
    required this.destination,
    required this.selected,
    required this.extended,
    required this.onTap,
  });

  final NavigationDestination destination;
  final bool selected;
  final bool extended;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    final item = AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : CamelliaMotion.state,
      curve: CamelliaMotion.enter,
      height: 48,
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      padding: EdgeInsets.symmetric(horizontal: extended ? 13 : 0),
      decoration: BoxDecoration(
        color: selected
            ? theme.colorScheme.primaryContainer
            : Colors.transparent,
        border: Border.all(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.16)
              : Colors.transparent,
        ),
        borderRadius: BorderRadius.circular(CamelliaRadius.surface),
      ),
      child: Row(
        mainAxisAlignment: extended
            ? MainAxisAlignment.start
            : MainAxisAlignment.center,
        children: [
          IconTheme(
            data: IconThemeData(color: foreground, size: 22),
            child: selected
                ? (destination.selectedIcon ?? destination.icon)
                : destination.icon,
          ),
          if (extended) ...[
            const SizedBox(width: 13),
            Expanded(
              child: Text(
                destination.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: foreground,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  letterSpacing: 0,
                ),
              ),
            ),
          ],
        ],
      ),
    );
    return Tooltip(
      message: extended ? '' : destination.label,
      child: Semantics(
        selected: selected,
        button: true,
        label: destination.label,
        child: Material(
          color: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          borderRadius: BorderRadius.circular(CamelliaRadius.surface),
          child: InkWell(onTap: onTap, child: item),
        ),
      ),
    );
  }
}
