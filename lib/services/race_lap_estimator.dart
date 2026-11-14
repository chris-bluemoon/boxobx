import '../models/telemetry_frame.dart';

/// How many laps the race is: GT7's own count for a lap race, or an
/// estimate for a timed race (GT7 sends no lap count then).
class RaceLaps {
  final int total;
  final bool estimated;

  /// What to plan fuel to: [total], or one more when a timed race's
  /// estimate is close to tipping into an extra lap (a slightly faster
  /// pace and the clock runs out a lap later) -- running dry costs far
  /// more than a splash.
  final int fuelSafeTotal;

  const RaceLaps({required this.total, this.estimated = false, int? fuelSafeTotal})
    : fuelSafeTotal = fuelSafeTotal ?? total;
}

/// Works out a timed race's lap count as it goes. When the clock runs
/// out you finish the lap you're on, so the race is the first lap that
/// ends at or past the time limit: laps done + time left / race pace,
/// rounded up. Race pace is the average of the last few clean laps (no
/// standing-start lap, no pit laps); until there is one, the lap count
/// in the saved strategy is used.
class RaceLapEstimator {
  /// The round's time limit (minutes); null for a lap race.
  int? raceLengthMinutes;

  /// The strategy's lap count -- the estimate until laps are timed.
  int? plannedLaps;

  /// An estimate within this fraction of a lap below the next whole lap
  /// could become one more.
  static const double _closeToExtraLap = 0.1;

  static const int _paceLaps = 5;

  final Map<int, int> _lapTimesMs = {};
  int? _lastSeenLap;

  /// Laps in a race of [minutes] at [lapMs] a lap (for the strategy).
  static int lapsFor(int minutes, int lapMs) => (minutes * 60000 / lapMs).ceil();

  void reset() {
    _lapTimesMs.clear();
    _lastSeenLap = null;
  }

  /// Feeds a (driving) frame in; [pitLaps] are laps with a pit stop
  /// (excluded from the pace).
  RaceLaps? update(TelemetryFrame frame, {Set<int> pitLaps = const {}}) {
    if (frame.totalLaps > 0) return RaceLaps(total: frame.totalLaps);

    final last = _lastSeenLap;
    if (last != null && frame.currentLap < last) reset();
    if (last != null && frame.currentLap == last + 1 && frame.lastLapTimeMs > 0) {
      _lapTimesMs[last] = frame.lastLapTimeMs;
    }
    _lastSeenLap = frame.currentLap;

    final minutes = raceLengthMinutes;
    if (minutes == null || minutes <= 0) return null;

    final clean = [
      for (final e in _lapTimesMs.entries)
        if (e.key > 1 && !pitLaps.contains(e.key)) e.value,
    ];
    if (clean.isEmpty) {
      final planned = plannedLaps;
      return planned == null || planned <= 0 ? null : RaceLaps(total: planned, estimated: true);
    }
    final recent = clean.length > _paceLaps ? clean.sublist(clean.length - _paceLaps) : clean;
    final pace = recent.reduce((a, b) => a + b) / recent.length;

    // Laps done; any we didn't see (the app joined late) count at pace.
    final done = frame.currentLap > 0 ? frame.currentLap - 1 : _lapTimesMs.length;
    final seen = _lapTimesMs.values.fold<int>(0, (sum, t) => sum + t);
    final elapsed = seen + (done - _lapTimesMs.length).clamp(0, done) * pace;
    final left = minutes * 60000 - elapsed;
    if (left <= 0) return RaceLaps(total: done, estimated: true);

    final exact = done + left / pace;
    final total = exact.ceil();
    return RaceLaps(total: total, estimated: true, fuelSafeTotal: total - exact < _closeToExtraLap ? total + 1 : total);
  }
}
