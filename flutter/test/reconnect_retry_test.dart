import 'dart:async';

import 'package:camellia_remote_app/models/reconnect_retry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('wall-clock jumps cannot change the monotonic retry trace', () {
    List<Duration> trace(Duration wallJump) {
      final clock = _Clock();
      final retry = clock.controller();
      final attempts = <Duration>[];
      void schedule() {
        retry.schedule(
          onRetry: () {
            attempts.add(clock.now);
            clock.wall = clock.wall.add(wallJump);
            schedule();
          },
          onExhausted: () {},
        );
      }

      schedule();
      clock.advance(const Duration(days: 31));
      expect(retry.exhausted, isTrue);
      expect(retry.hasPendingTimer, isFalse);
      expect(clock.activeTimers, 0);
      return attempts;
    }

    final expected = [
      1,
      3,
      7,
      15,
      23,
    ].map((s) => Duration(seconds: s)).toList();
    for (final seconds in [0, 1, 60, 7200, 30 * 86400]) {
      expect(trace(Duration(seconds: seconds)), expected);
      expect(trace(Duration(seconds: -seconds)), expected);
    }
  });

  test(
    'jitter and exponential delay have hard delay, attempt and budget caps',
    () {
      for (final random in [0.0, 0.5, 0.999999]) {
        final clock = _Clock();
        final retry = clock.controller(random: random);
        final delays = <Duration>[];
        void schedule() {
          final delay = retry.schedule(
            onRetry: () {
              expect(clock.now, lessThan(ReconnectRetry.budget));
              schedule();
            },
            onExhausted: () {},
          );
          if (delay != null) delays.add(delay);
        }

        schedule();
        clock.advance(const Duration(days: 365));
        expect(delays.first.inMilliseconds, inInclusiveRange(800, 1200));
        expect(delays.every((d) => d <= ReconnectRetry.maxDelay), isTrue);
        expect(retry.attempts, lessThanOrEqualTo(ReconnectRetry.maxAttempts));
        expect(retry.exhausted, isTrue);
        expect(clock.activeTimers, 0);
      }
    },
  );

  test('remaining budget clamps a new timer; deadline does not retry', () {
    final clock = _Clock();
    final retry = clock.controller();
    var attempts = 0;
    var exhausted = 0;
    Duration? schedule() => retry.schedule(
      onRetry: () => attempts++,
      onExhausted: () => exhausted++,
    );
    expect(schedule(), const Duration(seconds: 1));
    clock.advance(const Duration(seconds: 29));
    expect(attempts, 1);
    expect(schedule(), const Duration(seconds: 1));
    clock.advance(const Duration(seconds: 1));
    expect(attempts, 1);
    expect(exhausted, 1);
    expect(schedule(), isNull);
    expect(clock.activeTimers, 0);
  });

  test('duplicate errors keep one timer and cannot extend the deadline', () {
    final clock = _Clock();
    final retry = clock.controller();
    var attempts = 0;
    Duration? schedule() =>
        retry.schedule(onRetry: () => attempts++, onExhausted: () {});
    schedule();
    final owner = retry.generation;
    clock.advance(const Duration(milliseconds: 500));
    for (var i = 0; i < 32; i++) {
      expect(schedule(), const Duration(milliseconds: 500));
    }
    expect(retry.generation, owner);
    expect(clock.activeTimers, 1);
    clock.advance(const Duration(seconds: 1));
    expect(attempts, 1);
    clock.advance(const Duration(seconds: 29));
    expect(schedule(), isNull);
    expect(clock.activeTimers, 0);
  });

  test('late callbacks after close/cancel/success/new session cannot run', () {
    final clock = _Clock();
    final retry = clock.controller();
    var oldRetries = 0;
    var oldExhaustions = 0;
    for (var i = 0; i < 100; i++) {
      retry.reset();
      retry.schedule(
        onRetry: () => oldRetries++,
        onExhausted: () => oldExhaustions++,
      );
      final stale = clock.timers.last;
      retry.expire();
      retry.expire();
      expect(retry.schedule(onRetry: () {}, onExhausted: () {}), isNull);
      retry.reset();
      var newRetries = 0;
      retry.schedule(onRetry: () => newRetries++, onExhausted: () {});
      // Emulate a callback already queued by the runtime when cancel occurred.
      stale.callback();
      expect(clock.activeTimers, 1);
      clock.advance(const Duration(seconds: 1));
      expect(newRetries, 1);
    }
    expect(oldRetries, 0);
    expect(oldExhaustions, 0);
    expect(clock.activeTimers, 0);
  });

  test('suspend/resume is terminal and notifies once; manual retry resets', () {
    final clock = _Clock();
    final retry = clock.controller();
    var attempts = 0;
    var exhausted = 0;
    void schedule() => retry.schedule(
      onRetry: () => attempts++,
      onExhausted: () => exhausted++,
    );
    schedule();
    retry.expire(notify: true);
    retry.expire(notify: true);
    clock.advance(const Duration(days: 1));
    schedule();
    expect(attempts, 0);
    expect(exhausted, 1);
    expect(clock.activeTimers, 0);
    retry.reset();
    schedule();
    clock.advance(const Duration(seconds: 1));
    expect(attempts, 1);
    expect(retry.attempts, 1);
  });

  test(
    'late wake callback rechecks deadline before any reconnect side effect',
    () {
      final clock = _Clock();
      final retry = clock.controller();
      var attempts = 0;
      var exhausted = 0;
      retry.schedule(onRetry: () => attempts++, onExhausted: () => exhausted++);
      clock.now = const Duration(hours: 2);
      clock.timers.last.fire();
      expect(attempts, 0);
      expect(exhausted, 1);
      expect(retry.hasPendingTimer, isFalse);
    },
  );

  test('independent sessions cannot cancel or advance each other', () {
    final clock = _Clock();
    final a = clock.controller();
    final b = clock.controller();
    var aRetries = 0;
    var bRetries = 0;
    a.schedule(onRetry: () => aRetries++, onExhausted: () {});
    b.schedule(onRetry: () => bRetries++, onExhausted: () {});
    a.expire();
    clock.advance(const Duration(seconds: 1));
    expect(aRetries, 0);
    expect(bRetries, 1);
    expect(clock.activeTimers, 0);
  });
}

class _Clock {
  Duration now = Duration.zero;
  DateTime wall = DateTime.utc(2026, 10, 22);
  final timers = <_FakeTimer>[];

  int get activeTimers => timers.where((t) => t.isActive).length;

  ReconnectRetry controller({double random = 0.5}) => ReconnectRetry(
    now: () => now,
    random: () => random,
    createTimer: (delay, callback) {
      final timer = _FakeTimer(now + delay, callback);
      timers.add(timer);
      return timer;
    },
  );

  void advance(Duration duration) {
    final target = now + duration;
    while (true) {
      final due = timers.where((t) => t.isActive && t.due <= target).toList()
        ..sort((a, b) => a.due.compareTo(b.due));
      if (due.isEmpty) break;
      now = due.first.due;
      due.first.fire();
    }
    now = target;
  }
}

class _FakeTimer implements Timer {
  final Duration due;
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;

  _FakeTimer(this.due, this.callback);

  @override
  void cancel() => isActive = false;

  void fire() {
    if (!isActive) return;
    isActive = false;
    tick++;
    callback();
  }
}
