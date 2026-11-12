import '../models/practice_lap_record.dart';

/// Computes a fuel-per-lap average from logged practice laps, WEIGHTED
/// by shift quality -- a lap with a lot of short-shifting or
/// over-revving burned more fuel than a clean lap would have purely
/// from shift habit (independent of tire/fuel-map differences), so
/// treating every logged lap as an equally-trustworthy fuel-per-lap
/// sample would bias the prediction toward whatever the driver's
/// worst habits happened to be during practice, rather than toward
/// what a clean, repeatable stint should actually burn.
///
/// This is a SEPARATE calculation from FuelPredictor's live rolling
/// average (which has no visibility into shift quality at all, just
/// raw fuel delta per lap) -- RaceStrategyScreen prefers this one when
/// enough clean-lap data exists, since it's a strictly better estimate
/// of what the race itself will burn if the driver shifts cleanly.
class ShiftAwareFuelCalculator {
  /// Minimum cleanShiftRatio (see PracticeLapRecord) for a lap to be
  /// considered "clean enough" to include in the average -- a lap with
  /// a meaningful share of early/late shifts is excluded rather than
  /// dragging the average toward a pessimistic (over-fueled-estimate)
  /// or optimistic (under-fueled-estimate) number that doesn't
  /// represent repeatable driving.
  static const double _minCleanShiftRatio = 0.7;

  /// Minimum number of clean-enough laps required before this
  /// calculation is used at all -- a single clean lap could easily be
  /// an outlier (e.g. a short out-lap), so a small minimum sample size
  /// is required for the result to be trusted over the raw rolling
  /// average.
  static const int _minCleanLapCount = 2;

  /// Returns the average fuelConsumedPercent across laps that meet the
  /// clean-shift-ratio bar, or null if there isn't enough qualifying
  /// data yet (too few laps logged, or none were clean enough) -- in
  /// which case callers should fall back to a different estimate
  /// (e.g. FuelPredictor's raw rolling average, or the generic
  /// baseline assumption).
  static double? averagePercentPerLap(List<PracticeLapRecord> laps) {
    final cleanLaps = laps.where((lap) {
      final ratio = lap.cleanShiftRatio;
      // A lap with NO recorded shifts at all (ratio == null) is
      // neither penalized nor specially trusted -- include it as-is,
      // since the absence of shift data doesn't mean the lap was
      // dirty, just that shift tracking didn't have anything to
      // classify (e.g. a single-gear corner-only lap).
      return ratio == null || ratio >= _minCleanShiftRatio;
    }).toList();

    if (cleanLaps.length < _minCleanLapCount) return null;

    final total = cleanLaps.map((l) => l.fuelConsumedPercent).reduce((a, b) => a + b);
    final average = total / cleanLaps.length;
    return average > 0 ? average : null;
  }

  /// Fraction of ALL logged laps (not just clean ones) that met the
  /// clean-shift-ratio bar -- surfaced in the UI so the driver can see
  /// at a glance how much of their practice session was actually
  /// clean enough to trust, e.g. "6/10 laps clean".
  static int cleanLapCount(List<PracticeLapRecord> laps) {
    return laps.where((lap) {
      final ratio = lap.cleanShiftRatio;
      return ratio == null || ratio >= _minCleanShiftRatio;
    }).length;
  }
}
