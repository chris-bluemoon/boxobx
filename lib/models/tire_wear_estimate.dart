/// Result of TireWearTracker's lap-time-degradation analysis. GT7's
/// telemetry packet has no tire-wear-percentage field at all (confirmed
/// against community reverse-engineering docs) -- lap-time degradation
/// across consecutive laps on the same tire stint is the closest real
/// signal available, so this is a PROXY for wear, not a direct
/// measurement: a lap getting slower than the stint's best lap implies
/// grip (and so tire condition) is fading, independent of fuel load
/// changes (which are handled separately by FuelPrediction).
class TireWearEstimate {
  /// Percent slower the most recent lap was vs. the best lap recorded
  /// THIS STINT (not the whole session -- a pit stop/tire change resets
  /// the baseline). E.g. 2.5 means the last lap was 2.5% slower than
  /// this stint's best lap. 0.0 for the first completed lap of a stint
  /// (it IS the stint-best by definition, so there's nothing to compare
  /// against yet). Null only if no lap has completed this stint at all.
  final double? percentSlowerThanStintBest;

  /// How many consecutive laps of degrading (monotonically getting
  /// slower) lap times have been observed in a row -- a single slower
  /// lap is noise (traffic, a mistake); several in a row is a much
  /// stronger signal that the tire is genuinely falling off.
  final int consecutiveDegradingLaps;

  /// True once at least 1 completed lap on the current stint has been
  /// gathered, so the UI can distinguish "no laps completed yet this
  /// stint" from "no degradation detected".
  final bool hasEnoughData;

  const TireWearEstimate({
    this.percentSlowerThanStintBest,
    this.consecutiveDegradingLaps = 0,
    this.hasEnoughData = false,
  });

  factory TireWearEstimate.insufficientData() => const TireWearEstimate();
}
