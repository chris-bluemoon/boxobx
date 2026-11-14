import '../models/practice_lap_record.dart';

/// Fuel-per-lap from logged practice (and race) laps -- the measured
/// figure RaceStrategyScreen feeds PitStopCalculator in place of the
/// generic baseline.
///
/// A plain average over every logged lap except pit laps, which include
/// a refuel (negative consumption) or pit-lane running. Shift quality
/// deliberately plays no part: laps are no longer filtered or weighted
/// by short-shifting/over-revving.
class PracticeFuelCalculator {
  /// A single lap could easily be an outlier (e.g. an out-lap), so at
  /// least this many are needed before the average is used.
  static const int minLapCount = 2;

  /// Laps that count towards the average.
  static List<PracticeLapRecord> usableLaps(List<PracticeLapRecord> laps) =>
      laps.where((lap) => !lap.isPitLap && lap.fuelConsumedPercent > 0).toList();

  /// Average fuel used per lap (percent of tank), or null if there
  /// aren't enough usable laps yet -- callers then fall back to the live
  /// FuelPredictor figure or the generic baseline.
  static double? averagePercentPerLap(List<PracticeLapRecord> laps) {
    final usable = usableLaps(laps);
    if (usable.length < minLapCount) return null;
    return usable.map((l) => l.fuelConsumedPercent).reduce((a, b) => a + b) / usable.length;
  }
}
