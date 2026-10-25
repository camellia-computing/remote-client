import 'dart:async';
import 'dart:math';

typedef RetryTimerFactory = Timer Function(Duration, void Function());

/// One foreground connect operation. Wall time is deliberately not a dependency.
///
/// The runtime's monotonic clock measures the budget. A reported app suspension
/// ends the operation (rather than guessing whether a platform clock includes
/// sleep); resuming never resurrects it. A manual reconnect starts a new budget.
class ReconnectRetry {
  static const budget = Duration(seconds: 30);
  static const maxDelay = Duration(seconds: 8);
  static const maxAttempts = 6;

  final Duration Function() _now;
  final double Function() _random;
  final RetryTimerFactory _createTimer;
  Duration? _startedAt;
  Duration? _dueAt;
  Timer? _timer;
  int _attempts = 0;
  int _generation = 0;
  bool _exhausted = false;
  void Function()? _onExhausted;

  ReconnectRetry({
    Duration Function()? now,
    double Function()? random,
    RetryTimerFactory? createTimer,
  }) : _now = now ?? _monotonicClock(),
       _random = random ?? Random().nextDouble,
       _createTimer = createTimer ?? Timer.new;

  static Duration Function() _monotonicClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  int get generation => _generation;
  int get attempts => _attempts;
  bool get exhausted => _exhausted;
  bool get hasPendingTimer => _timer != null;

  /// Duplicate error events retain the same timer, deadline and attempt count.
  /// Callbacks must be synchronous: generation is checked immediately before use.
  Duration? schedule({
    required void Function() onRetry,
    required void Function() onExhausted,
  }) {
    if (_exhausted) return null;
    _onExhausted = onExhausted;
    final now = _now();
    _startedAt ??= now;
    final remaining = budget - (now - _startedAt!);
    if (remaining <= Duration.zero || _attempts >= maxAttempts) {
      expire();
      return null;
    }
    if (_timer != null) {
      final wait = _dueAt! - now;
      return wait > Duration.zero ? wait : Duration.zero;
    }

    final baseMs = min(1000 * (1 << _attempts), maxDelay.inMilliseconds);
    // +/-20% jitter, clamped to both the per-delay and total-operation limits.
    final jitteredMs = (baseMs * (0.8 + 0.4 * _random())).round();
    final delay = Duration(
      microseconds: min(
        min(jitteredMs * 1000, maxDelay.inMicroseconds),
        remaining.inMicroseconds,
      ),
    );
    final owner = ++_generation;
    _dueAt = now + delay;
    _timer = _createTimer(delay, () {
      if (owner != _generation || _exhausted) return;
      _timer = null;
      _dueAt = null;
      if (_now() - _startedAt! >= budget) {
        expire(notify: true);
        return;
      }
      _attempts++;
      onRetry();
    });
    return delay;
  }

  /// Cancel/close/suspend is terminal until an explicit new operation/reset.
  void expire({bool notify = false}) {
    if (_exhausted) return;
    _invalidateTimer();
    _exhausted = true;
    final onExhausted = _onExhausted;
    _onExhausted = null;
    if (notify) onExhausted?.call();
  }

  /// Success, manual retry, new session, or changed error classification.
  void reset() {
    _invalidateTimer();
    _startedAt = null;
    _attempts = 0;
    _exhausted = false;
    _onExhausted = null;
  }

  void _invalidateTimer() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _dueAt = null;
  }
}
