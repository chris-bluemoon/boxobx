import '../models/shift_event.dart';

/// Looks at the tracked recent-shift window (see ShiftHistoryTracker)
/// and decides whether there's a clear enough bad pattern to proactively
/// warn the driver about -- distinct from the dashboard card's "dominant
/// timing" display, this is specifically the trigger condition for
/// Gunther to speak up unprompted (see ProactiveCoachTrigger).
class ShiftCoachAdvisor {
  /// Minimum number of the tracked shifts that must share the same bad
  /// timing before it's considered a real pattern worth calling out,
  /// rather than noise (e.g. one awkward downshift recovery).
  static const int minMatchingShifts = 3;

  /// Returns the bad ShiftTiming (early or late) if at least
  /// [minMatchingShifts] of the tracked shifts share it, otherwise null
  /// (no clear pattern, or the dominant pattern is "good").
  static ShiftTiming? detectBadPattern(List<ShiftEvent> recentShifts) {
    if (recentShifts.length < minMatchingShifts) return null;

    final earlyCount = recentShifts.where((s) => s.timing == ShiftTiming.early).length;
    final lateCount = recentShifts.where((s) => s.timing == ShiftTiming.late).length;

    if (earlyCount >= minMatchingShifts && earlyCount >= lateCount) {
      return ShiftTiming.early;
    }
    if (lateCount >= minMatchingShifts) {
      return ShiftTiming.late;
    }
    return null;
  }
}
