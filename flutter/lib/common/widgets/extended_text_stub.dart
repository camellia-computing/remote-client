import 'package:flutter/widgets.dart';

enum TextOverflowPosition { start, end, middle }

class TextOverflowWidget extends StatelessWidget {
  final Widget child;
  final TextOverflowPosition position;

  const TextOverflowWidget({
    super.key,
    required this.child,
    this.position = TextOverflowPosition.end,
  });

  @override
  Widget build(BuildContext context) => child;
}

class ExtendedText extends Text {
  const ExtendedText(
    super.data, {
    super.key,
    super.style,
    super.strutStyle,
    super.textAlign,
    super.textDirection,
    super.locale,
    super.softWrap,
    super.overflow,
    super.textScaler,
    super.maxLines,
    super.semanticsLabel,
    super.textWidthBasis,
    super.textHeightBehavior,
    Widget? overflowWidget,
  });
}
