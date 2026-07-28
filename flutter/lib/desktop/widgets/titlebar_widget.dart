import 'package:flutter/material.dart';

const sidebarColor = Color(0xFF3730A3);
const backgroundStartColor = Color(0xFF4F46E5);
const backgroundEndColor = Color(0xFF4F46E5);

class DesktopTitleBar extends StatelessWidget {
  final Widget? child;

  const DesktopTitleBar({Key? key, this.child}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: backgroundStartColor,
      child: Row(children: [Expanded(child: child ?? Offstage())]),
    );
  }
}
