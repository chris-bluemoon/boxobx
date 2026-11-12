import '../models/shift_event.dart';
import 'shift_coach_advisor.dart';

/// Decides when Gunther should speak up UNPROMPTED (no push-to-talk)
/// about a sustained shift-habit problem, with a per-pattern cooldown
/// so a detected bad pattern doesn't trigger a new callout on every
/// single frame it remains true.
class ProactiveCoachTrigger {
  final Duration cooldown;
  final DateTime Function() _now;

  ProactiveCoachTrigger({
    this.cooldown = const Duration(seconds: 60),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  DateTime? _lastFiredAt;
  ShiftTiming? _lastFiredPattern;

  /// Feeds the current recent-shift window in. Returns the bad pattern
  /// to call out if one should fire right now (and records that it
  /// fired, starting the cooldown), or null if nothing should fire
  /// (either no bad pattern detected, or still in cooldown since the
  /// last callout).
  ShiftTiming? check(List<ShiftEvent> recentShifts) {
    final pattern = ShiftCoachAdvisor.detectBadPattern(recentShifts);
    if (pattern == null) return null;

    final now = _now();
    final lastFiredAt = _lastFiredAt;
    // Cooldown only blocks repeating the SAME pattern -- if the driver
    // flips from short-shifting to over-revving (or vice versa), that's
    // a new, different piece of feedback worth surfacing immediately
    // rather than waiting out a cooldown that was timing a different
    // problem.
    if (lastFiredAt != null &&
        _lastFiredPattern == pattern &&
        now.difference(lastFiredAt) < cooldown) {
      return null;
    }

    _lastFiredAt = now;
    _lastFiredPattern = pattern;
    return pattern;
  }

  /// Clears cooldown state -- call alongside a manual telemetry reset
  /// so a stale cooldown from a previous session doesn't suppress a
  /// genuine new callout.
  void reset() {
    _lastFiredAt = null;
    _lastFiredPattern = null;
  }
}
