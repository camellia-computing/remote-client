import 'package:flutter/material.dart';

import '../../ui/remote_ui_models.dart';

/// Geometry boundary between the full-session overlay and the command bar.
///
/// The overlay must span the viewport so the command bar can dock to any edge.
/// The command bar itself must not inherit that full cross-axis constraint: if
/// one of its descendants fails to build, Flutter's release [ErrorWidget]
/// otherwise becomes a viewport-sized opaque surface over the remote canvas.
class RemoteToolbarOverlaySurface extends StatelessWidget {
  const RemoteToolbarOverlaySurface({
    super.key,
    required this.edge,
    required this.fraction,
    required this.toolbar,
    this.preview,
  });

  /// The command bar plus its collapse handle currently needs less than 84
  /// logical pixels. Keep a small allowance for borders, shadows and future
  /// density changes while retaining a strict non-viewport failure boundary.
  static const double maxCrossAxisExtent = 96;

  final RemoteCommandBarEdge edge;
  final double fraction;
  final Widget toolbar;
  final Widget? preview;

  Alignment get _alignment {
    final alongEdge = fraction.clamp(0.0, 1.0) * 2 - 1;
    return switch (edge) {
      RemoteCommandBarEdge.top => Alignment(alongEdge, -1),
      RemoteCommandBarEdge.right => Alignment(1, alongEdge),
      RemoteCommandBarEdge.bottom => Alignment(alongEdge, 1),
      RemoteCommandBarEdge.left => Alignment(-1, alongEdge),
    };
  }

  BoxConstraints get _toolbarConstraints => edge.isHorizontal
      ? const BoxConstraints(maxHeight: maxCrossAxisExtent)
      : const BoxConstraints(maxWidth: maxCrossAxisExtent);

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        if (preview != null) IgnorePointer(child: preview),
        Align(
          alignment: _alignment,
          child: ConstrainedBox(
            constraints: _toolbarConstraints,
            child: toolbar,
          ),
        ),
      ],
    );
  }
}
