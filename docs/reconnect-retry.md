# Automatic reconnect budget

Flutter automatic reconnect is one foreground operation, not an unlimited
background service. Offline recovery after a connected peer changes account,
and errors explicitly marked retryable by the core, use the same bounds:

- 30 seconds measured by a runtime monotonic `Stopwatch`, never wall time.
- At most six automatic attempts, exponential backoff with ±20% jitter, and an
  eight-second maximum delay. Each delay is also clamped to the remaining budget.
- A delayed callback rechecks its operation generation and deadline before
  requesting any reconnect. Duplicate errors do not replace the pending timer.
- Success, changed error classification, explicit retry, new session, and close
  invalidate old callbacks. Manual retry begins a new operation.
- Suspension/hidden/detached lifecycle notifications end automatic recovery.
  Resume also ends a pending operation, to cover platforms that omit a sleep
  notification. Resume never silently grants another budget; manual retry is
  still available. Ordinary `inactive` (for example a focus transition) is not
  considered suspension.

This policy does not assume that every platform's monotonic clock counts system
sleep. Where lifecycle events are absent, the runtime monotonic elapsed time is
the authority; real platform sleep/wake behavior remains an integration gate.
Restart-device acknowledgement and its separate probing lifecycle are not
implemented by this retry budget.

Deterministic regression tests:

```sh
cd flutter
flutter test test/reconnect_retry_test.dart
```

The tests inject separate monotonic and wall clocks and a controlled timer
scheduler. They do not sleep, alter host time, or open a full-screen session.
