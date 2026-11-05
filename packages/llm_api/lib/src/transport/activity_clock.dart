/// How much of a wall-clock span the host app was actually *active*.
///
/// Mobile OSes freeze (or aggressively throttle) a backgrounded process: the
/// response bytes pile up in the kernel buffer, but Dart timers stop firing.
/// A naive `Stream.timeout` therefore reports "stream stalled" the instant the
/// app returns to the foreground, even though the connection is healthy. The
/// watchdog asks this clock instead of the wall clock, so suspended time does
/// not count against the idle budget.
library;

/// Source of "active time" information for the streaming watchdog.
abstract class ActivityClock {
  const ActivityClock();

  /// Whether the host is active right now (foreground / not suspended).
  bool get isActive;

  /// Current wall-clock time.
  DateTime now();

  /// Portion of `since..now` spent active (background spans excluded).
  Duration activeSince(DateTime since);
}

/// Default clock: everything counts. Used on desktop and in tests.
class AlwaysActiveClock extends ActivityClock {
  const AlwaysActiveClock();

  @override
  bool get isActive => true;

  @override
  DateTime now() => DateTime.now();

  @override
  Duration activeSince(DateTime since) {
    final span = DateTime.now().difference(since);
    return span.isNegative ? Duration.zero : span;
  }
}
