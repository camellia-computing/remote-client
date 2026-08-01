import 'package:flutter/material.dart';

import 'adaptive_layout.dart';

/// Opens settings without introducing another root navigation destination.
/// Compact layouts use a full-screen route; larger layouts stay in the current
/// workspace and use a modal surface sized for the available window.
Future<T?> showSettingsOverlay<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  List<Widget> actions = const [],
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  final width = MediaQuery.sizeOf(context).width;
  if (width < AppLayout.compactBreakpoint) {
    return Navigator.of(context).push<T>(
      MaterialPageRoute<T>(
        fullscreenDialog: true,
        builder: (routeContext) => Scaffold(
          appBar: AppBar(title: Text(title), actions: actions),
          body: SafeArea(top: false, child: builder(routeContext)),
        ),
      ),
    );
  }

  final medium = width < AppLayout.expandedBreakpoint;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.42),
    transitionDuration: AppMotion.duration(context, AppMotion.modal),
    pageBuilder: (dialogContext, _, _) {
      final size = MediaQuery.sizeOf(dialogContext);
      final surface = Material(
        color: Theme.of(dialogContext).colorScheme.surface,
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(medium ? 20 : 24),
        child: Column(
          children: [
            SizedBox(
              height: 60,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(22, 0, 12, 0),
                child: Row(
                  children: [
                    Icon(
                      Icons.settings_rounded,
                      size: 22,
                      color: Theme.of(dialogContext).colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(dialogContext).textTheme.titleLarge,
                      ),
                    ),
                    if (actions.isNotEmpty) ...[
                      const SizedBox(width: 12),
                      ...actions,
                    ],
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: MaterialLocalizations.of(
                        dialogContext,
                      ).closeButtonTooltip,
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
            ),
            Divider(
              height: 1,
              color: Theme.of(dialogContext).colorScheme.outlineVariant,
            ),
            Expanded(child: builder(dialogContext)),
          ],
        ),
      );
      if (medium) {
        return SafeArea(
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: SizedBox(
              width: (size.width * 0.90).clamp(560.0, 820.0),
              height: size.height,
              child: surface,
            ),
          ),
        );
      }
      return SafeArea(
        minimum: const EdgeInsets.all(32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 1040,
              maxHeight: 760,
              minWidth: 760,
              minHeight: 560,
            ),
            child: surface,
          ),
        ),
      );
    },
    transitionBuilder: (dialogContext, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: AppMotion.enterCurve,
        reverseCurve: AppMotion.exitCurve,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: medium ? const Offset(0.04, 0) : const Offset(0, 0.025),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}
