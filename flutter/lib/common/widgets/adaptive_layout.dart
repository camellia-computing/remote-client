import 'package:flutter/material.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';

enum AppLayoutSize { compact, medium, expanded }

/// Shared layout breakpoints for application UI. Remote canvas geometry keeps
/// its own sizing rules and is deliberately not driven by this helper.
class AppLayout {
  AppLayout._();

  static const double compactBreakpoint = 600;
  static const double expandedBreakpoint = 1024;

  /// Width at which a two-pane home workspace becomes comfortable.
  static const double splitBreakpoint = 1024;

  static AppLayoutSize forWidth(double width) {
    if (width < compactBreakpoint) return AppLayoutSize.compact;
    if (width < expandedBreakpoint) return AppLayoutSize.medium;
    return AppLayoutSize.expanded;
  }

  static EdgeInsets pagePadding(BuildContext context) {
    switch (forWidth(MediaQuery.sizeOf(context).width)) {
      case AppLayoutSize.compact:
        return const EdgeInsets.all(16);
      case AppLayoutSize.medium:
        return const EdgeInsets.all(24);
      case AppLayoutSize.expanded:
        return const EdgeInsets.all(32);
    }
  }
}

class AppMotion {
  AppMotion._();

  static bool isReduced(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  static Duration duration(BuildContext context, Duration normal) =>
      isReduced(context) ? Duration.zero : normal;

  static const Duration hover = CamelliaMotion.hover;
  static const Duration feedback = CamelliaMotion.feedback;
  static const Duration stateChange = CamelliaMotion.state;
  static const Duration contentSwap = CamelliaMotion.content;
  static const Duration modal = CamelliaMotion.modal;
  static const Duration route = CamelliaMotion.route;

  static const Curve standardCurve = CamelliaMotion.standard;
  static const Curve enterCurve = CamelliaMotion.enter;
  static const Curve exitCurve = CamelliaMotion.exit;
}

class AdaptiveContent extends StatelessWidget {
  const AdaptiveContent({
    super.key,
    required this.child,
    this.maxWidth = 1180,
    this.padding,
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: padding ?? AppLayout.pagePadding(context),
          child: child,
        ),
      ),
    );
  }
}

enum AppContentState {
  loading,
  refreshing,
  loadingMore,
  empty,
  noResults,
  error,
  offline,
  disabled,
  submitting,
  success,
}

class AppStatePane extends StatelessWidget {
  const AppStatePane({
    super.key,
    required this.state,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final AppContentState state;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color) = switch (state) {
      AppContentState.loading => (Icons.sync_rounded, CamelliaColors.azure),
      AppContentState.refreshing => (
        Icons.refresh_rounded,
        CamelliaColors.aqua,
      ),
      AppContentState.loadingMore => (
        Icons.keyboard_arrow_down_rounded,
        CamelliaColors.azure,
      ),
      AppContentState.empty => (Icons.inbox_outlined, scheme.onSurfaceVariant),
      AppContentState.noResults => (
        Icons.search_off_rounded,
        scheme.onSurfaceVariant,
      ),
      AppContentState.error => (Icons.error_outline_rounded, scheme.error),
      AppContentState.offline => (
        Icons.cloud_off_outlined,
        scheme.onSurfaceVariant,
      ),
      AppContentState.disabled => (
        Icons.block_rounded,
        scheme.onSurfaceVariant,
      ),
      AppContentState.submitting => (Icons.sync_rounded, CamelliaColors.orchid),
      AppContentState.success => (
        Icons.check_circle_outline,
        CamelliaColors.aqua,
      ),
    };
    final isBusy = switch (state) {
      AppContentState.loading ||
      AppContentState.refreshing ||
      AppContentState.loadingMore ||
      AppContentState.submitting => true,
      _ => false,
    };
    final showProgress = isBusy && !AppMotion.isReduced(context);
    return AnimatedSwitcher(
      duration: AppMotion.duration(context, AppMotion.contentSwap),
      switchInCurve: AppMotion.enterCurve,
      switchOutCurve: AppMotion.exitCurve,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.025),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: Center(
        key: ValueKey<AppContentState>(state),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showProgress)
                  SizedBox(
                    height: 30,
                    width: 30,
                    child: CircularProgressIndicator(
                      color: color,
                      strokeWidth: 2.6,
                    ),
                  )
                else
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SizedBox(
                      height: 48,
                      width: 48,
                      child: Icon(icon, color: color, size: 26),
                    ),
                  ),
                const SizedBox(height: 14),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: 16),
                  FilledButton(onPressed: onAction, child: Text(actionLabel!)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AppStateTransition extends StatelessWidget {
  const AppStateTransition({
    super.key,
    required this.stateKey,
    required this.child,
    this.alignment = Alignment.topCenter,
  });

  final Object stateKey;
  final Widget child;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: AppMotion.duration(context, AppMotion.contentSwap),
      switchInCurve: AppMotion.enterCurve,
      switchOutCurve: AppMotion.exitCurve,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: alignment,
        children: [...previousChildren, ?currentChild],
      ),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SizeTransition(sizeFactor: animation, child: child),
      ),
      child: KeyedSubtree(key: ValueKey<Object>(stateKey), child: child),
    );
  }
}
