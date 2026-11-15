import '../models/practice_lap_record.dart';
import '../models/time_trial_lap.dart';
import 'stint_summary.dart';

/// One tyre's pace for the home page: its best and average clean dry
/// lap from practice and race stints, and its time-trial best.
class TyreBestLap {
  final String compound;

  /// Fastest counted lap (practice or race), ms; null if only a time
  /// trial was run on it.
  final int? bestMs;

  /// Average of the counted laps, ms.
  final double? averageMs;

  /// Counted laps behind those figures.
  final int laps;

  /// Fastest time-trial lap on this tyre, ms.
  final int? timeTrialMs;

  const TyreBestLap({
    required this.compound,
    this.bestMs,
    this.averageMs,
    this.laps = 0,
    this.timeTrialMs,
  });

  /// The quickest of the two, for sorting.
  int get quickestMs => [?bestMs, ?timeTrialMs].reduce((a, b) => a < b ? a : b);

  /// Per tyre, quickest first. Only laps each stint counts (no pit laps,
  /// spins or traffic -- see StintSummary) and only dry ones (no rain
  /// preset set, gauge under 10%), so wet laps don't make a tyre look slow.
  static List<TyreBestLap> fromLaps(
    List<PracticeLapRecord> laps, {
    List<TimeTrialLap> timeTrial = const [],
  }) {
    final byTyre = <String, List<int>>{};
    for (final stint in StintSummary.fromLaps(laps)) {
      for (final lap in stint.laps) {
        if (lap.isPitLap || lap.lapTimeMs <= 0 || !stint.counts(lap)) continue;
        if (lap.weather != null || (lap.waterPercent ?? 0) >= 10) continue;
        byTyre.putIfAbsent(lap.tireCompound, () => []).add(lap.lapTimeMs);
      }
    }
    final ttBest = <String, int>{};
    for (final lap in timeTrial) {
      if (lap.lapTimeMs <= 0) continue;
      final b = ttBest[lap.tireCompound];
      if (b == null || lap.lapTimeMs < b) {
        ttBest[lap.tireCompound] = lap.lapTimeMs;
      }
    }
    final result = [
      for (final tyre in {...byTyre.keys, ...ttBest.keys})
        TyreBestLap(
          compound: tyre,
          bestMs: byTyre[tyre]?.reduce((a, b) => a < b ? a : b),
          averageMs: byTyre[tyre] == null
              ? null
              : byTyre[tyre]!.reduce((a, b) => a + b) / byTyre[tyre]!.length,
          laps: byTyre[tyre]?.length ?? 0,
          timeTrialMs: ttBest[tyre],
        ),
    ]..sort((a, b) => a.quickestMs.compareTo(b.quickestMs));
    return result;
  }
}
