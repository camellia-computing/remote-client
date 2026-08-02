import 'package:flutter/material.dart';

enum DeviceCategoryLayout { selector, bar, rail }

DeviceCategoryLayout deviceCategoryLayoutForWidth(double width) => width < 520
    ? DeviceCategoryLayout.selector
    : width < 840
    ? DeviceCategoryLayout.bar
    : DeviceCategoryLayout.rail;

double deviceSearchWidth(double availableWidth, {bool focused = false}) {
  if (availableWidth < 520) return availableWidth;
  final preferred = focused ? 280.0 : 208.0;
  return preferred.clamp(0, availableWidth * 0.52).toDouble();
}

class DeviceOptionMenuItem<T> {
  const DeviceOptionMenuItem({
    required this.value,
    required this.label,
    required this.icon,
  });

  final T value;
  final String label;
  final IconData icon;
}

class DeviceOptionMenuButton<T> extends StatelessWidget {
  const DeviceOptionMenuButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.options,
    required this.selectedValue,
    required this.onSelected,
    this.enabled = true,
  });

  final String tooltip;
  final IconData icon;
  final List<DeviceOptionMenuItem<T>> options;
  final T selectedValue;
  final ValueChanged<T> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox.square(
      dimension: 44,
      child: PopupMenuButton<T>(
        tooltip: tooltip,
        enabled: enabled,
        position: PopupMenuPosition.under,
        offset: const Offset(0, 4),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 184, maxWidth: 216),
        onSelected: onSelected,
        itemBuilder: (context) => [
          for (final option in options)
            PopupMenuItem<T>(
              value: option.value,
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Semantics(
                selected: option.value == selectedValue,
                child: Row(
                  children: [
                    SizedBox(width: 24, child: Icon(option.icon, size: 18)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        option.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 18,
                      child: option.value == selectedValue
                          ? Icon(
                              Icons.check_rounded,
                              size: 18,
                              color: theme.colorScheme.primary,
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            ),
        ],
        child: Semantics(
          button: true,
          enabled: enabled,
          label: tooltip,
          excludeSemantics: true,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 19),
            ),
          ),
        ),
      ),
    );
  }
}
