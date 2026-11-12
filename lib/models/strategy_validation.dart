/// How a real practice-session fuel reading compares against the
/// planned strategy's assumption (see StrategyValidator).
enum StrategyFitness {
  /// Not enough practice-lap data yet to compare.
  insufficientData,

  /// Real consumption is close enough to the plan's assumption that the
  /// planned pit laps should still hold.
  onPlan,

  /// Burning MORE fuel per lap than planned -- the planned pit stop(s)
  /// will happen too late; recommend pitting earlier.
  burningMoreThanPlanned,

  /// Burning LESS fuel per lap than planned -- there's room to extend a
  /// stint later than planned (or potentially drop a stop).
  burningLessThanPlanned,
}

/// Result of comparing a RaceStrategy's fuel assumption against real
/// telemetry gathered during a practice session (see
/// StrategyValidator.evaluate).
class StrategyValidation {
  final StrategyFitness fitness;

  /// Real measured percent-per-lap from practice telemetry. Null if
  /// fitness is insufficientData.
  final double? actualPercentPerLap;

  /// The strategy's original assumption, carried through for display
  /// (RaceStrategy.assumedPercentPerLap).
  final double assumedPercentPerLap;

  /// Recommended adjusted pit lap, recalculated from actualPercentPerLap
  /// against the same starting fuel/race length the original plan used.
  /// Null if fitness is insufficientData or onPlan (no change needed).
  final int? recommendedPitLap;

  /// Plain-English warning if practice-session tire degradation (see
  /// TireWearEstimate) suggests the planned stint length may be too
  /// long for the selected compound -- null if there's no real
  /// degradation signal yet, or it doesn't contradict the plan.
  final String? tireWearWarning;

  const StrategyValidation({
    required this.fitness,
    this.actualPercentPerLap,
    required this.assumedPercentPerLap,
    this.recommendedPitLap,
    this.tireWearWarning,
  });

  factory StrategyValidation.insufficientData({required double assumedPercentPerLap}) =>
      StrategyValidation(
        fitness: StrategyFitness.insufficientData,
        assumedPercentPerLap: assumedPercentPerLap,
      );

  factory StrategyValidation.fromMap(Map<String, dynamic> map) => StrategyValidation(
        fitness: StrategyFitness.values.byName(map['fitness'] as String),
        actualPercentPerLap: (map['actualPercentPerLap'] as num?)?.toDouble(),
        assumedPercentPerLap: (map['assumedPercentPerLap'] as num).toDouble(),
        recommendedPitLap: (map['recommendedPitLap'] as num?)?.toInt(),
        tireWearWarning: map['tireWearWarning'] as String?,
      );

  Map<String, dynamic> toMap() => {
        'fitness': fitness.name,
        'actualPercentPerLap': actualPercentPerLap,
        'assumedPercentPerLap': assumedPercentPerLap,
        'recommendedPitLap': recommendedPitLap,
        'tireWearWarning': tireWearWarning,
      };
}
