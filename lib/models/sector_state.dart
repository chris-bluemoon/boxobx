/// Live sector timing (see SectorCalculator).
class SectorState {
  /// Kept for Gunther's context; not currently set (layouts are
  /// recognised by position, not by name).
  final String? activeTrackName;

  /// Sector being driven now: 0 = S1, 1 = S2, 2 = S3.
  final int currentSectorIndex;

  /// Whether this layout's sector lines are known yet. False until a
  /// full lap has been driven here (the first one teaches the lines).
  final bool mapped;

  /// Sector times completed so far on the lap in progress (ms, from the
  /// race clock -- not yet squared up with GT7's lap time).
  final List<int> currentLapSplitsMs;

  /// The last completed lap's three sector times (ms), adding up exactly
  /// to GT7's lap time. Null if that lap couldn't be split (lines not
  /// known, a pause, a reset).
  final List<int>? lastLapSectorsMs;

  /// True only on the frame a lap completed -- when [lastLapSectorsMs]
  /// belongs to the lap just logged.
  final bool lapJustCompleted;

  /// Live delta to the reference lap at this point on track (ms,
  /// negative = ahead of it). Null when there's nothing to compare with
  /// (see SectorCalculator).
  final int? liveDeltaMs;

  /// Lap time of the reference the delta is against -- the fastest clean
  /// lap at this layout in this car.
  final int? referenceLapMs;

  const SectorState({
    this.activeTrackName,
    this.currentSectorIndex = 0,
    this.mapped = false,
    this.currentLapSplitsMs = const [],
    this.lastLapSectorsMs,
    this.lapJustCompleted = false,
    this.liveDeltaMs,
    this.referenceLapMs,
  });

  /// Sectors of the lap that completed on this frame, else null.
  List<int>? get justCompletedSectorsMs => lapJustCompleted ? lastLapSectorsMs : null;

  /// Best time in each sector across [laps]' sector lists (nulls skipped).
  static List<int?> bestSectors(Iterable<List<int>?> laps) {
    final best = <int?>[null, null, null];
    for (final sectors in laps) {
      if (sectors == null || sectors.length != 3) continue;
      for (var i = 0; i < 3; i++) {
        if (best[i] == null || sectors[i] < best[i]!) best[i] = sectors[i];
      }
    }
    return best;
  }

  /// Sum of the best sectors -- the lap you'd do stringing them together.
  static int? idealLapMs(Iterable<List<int>?> laps) {
    final best = bestSectors(laps);
    return best.contains(null) ? null : best.fold<int>(0, (sum, s) => sum + s!);
  }

  /// e.g. "32.104" or "1:02.104".
  static String format(int ms) {
    final minutes = ms ~/ 60000;
    final seconds = ((ms % 60000) / 1000).toStringAsFixed(3);
    return minutes > 0 ? '$minutes:${seconds.padLeft(6, '0')}' : seconds;
  }
}
