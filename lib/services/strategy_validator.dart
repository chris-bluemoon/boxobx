import '../models/fuel_prediction.dart';
import '../models/race_briefing.dart';
import '../models/race_strategy.dart';
import '../models/strategy_validation.dart';
import '../models/tire_wear_estimate.dart';

/// Checks a RaceStrategy's fuel assumption against REAL telemetry
/// gathered during a practice session -- the AI's assumedPercentPerLap
/// is only ever a rough prior (see RaceStrategistService's prompt); the
/// driver's actual car/driving style/BOP on the real track is the
/// ground truth, and this is what reconciles the two.
///
/// Reuses the existing FuelPredictor/FuelPrediction pipeline (already
/// running live during any session, practice or race) rather than
/// building a second, parallel fuel-tracking mechanism.
class StrategyValidator {
  /// Minimum relative difference between assumed and actual
  /// percent-per-lap before it's worth flagging as off-plan, rather
  /// than reporting "on plan" for a trivial, within-noise difference.
  static const double _significantDifferenceThreshold = 0.15; // 15%

  /// How many consecutive degrading laps (see TireWearEstimate) before
  /// warning that the planned stint length may be too long for the
  /// selected compound -- a single degrading lap is noise, several in a
  /// row is a real signal.
  static const int _degradingLapsWarningThreshold = 3;

  /// Compares the strategy's fuel assumption against a live
  /// FuelPrediction from practice-session telemetry, and the
  /// originating briefing (for starting fuel / total laps context when
  /// recalculating a recommended pit lap). tireWearEstimate is optional
  /// (from the same practice session's TireWearTracker) -- when
  /// provided and showing a real degradation streak, adds a
  /// plain-English warning about the planned stint length.
  StrategyValidation evaluate({
    required RaceStrategy strategy,
    required RaceBriefing briefing,
    required FuelPrediction practiceFuelPrediction,
    TireWearEstimate? tireWearEstimate,
  }) {
    final tireWearWarning = _buildTireWearWarning(strategy, tireWearEstimate);

    if (!practiceFuelPrediction.hasEnoughData || practiceFuelPrediction.percentPerLap == null) {
      return StrategyValidation(
        fitness: StrategyFitness.insufficientData,
        assumedPercentPerLap: strategy.assumedPercentPerLap,
        tireWearWarning: tireWearWarning,
      );
    }

    final actual = practiceFuelPrediction.percentPerLap!;
    final assumed = strategy.assumedPercentPerLap;

    if (assumed <= 0) {
      // Can't meaningfully compare against a non-positive assumption --
      // treat as insufficient rather than dividing by zero/garbage.
      return StrategyValidation(
        fitness: StrategyFitness.insufficientData,
        assumedPercentPerLap: assumed,
        tireWearWarning: tireWearWarning,
      );
    }

    final relativeDifference = (actual - assumed) / assumed;

    if (relativeDifference.abs() < _significantDifferenceThreshold) {
      return StrategyValidation(
        fitness: StrategyFitness.onPlan,
        actualPercentPerLap: actual,
        assumedPercentPerLap: assumed,
        tireWearWarning: tireWearWarning,
      );
    }

    // Recompute how many laps the starting fuel actually lasts at the
    // REAL consumption rate, to suggest a concrete adjusted pit lap
    // rather than just flagging "this is wrong" with no actionable fix.
    final lapsOnRealConsumption = (briefing.startingFuelPercent / actual).floor();

    return StrategyValidation(
      fitness: relativeDifference > 0
          ? StrategyFitness.burningMoreThanPlanned
          : StrategyFitness.burningLessThanPlanned,
      actualPercentPerLap: actual,
      assumedPercentPerLap: assumed,
      recommendedPitLap: lapsOnRealConsumption,
      tireWearWarning: tireWearWarning,
    );
  }

  String? _buildTireWearWarning(RaceStrategy strategy, TireWearEstimate? tireWearEstimate) {
    if (tireWearEstimate == null ||
        !tireWearEstimate.hasEnoughData ||
        tireWearEstimate.consecutiveDegradingLaps < _degradingLapsWarningThreshold) {
      return null;
    }

    // Longest planned stint length (laps between stops, or from the
    // start/last stop to the finish) -- this is the stint most at risk
    // if the tire degrades faster than planned laps assume.
    final stintStarts = [0, ...strategy.pitStops.map((p) => p.lap)];
    var longestStint = 0;
    for (var i = 0; i < stintStarts.length; i++) {
      final end = i + 1 < stintStarts.length ? stintStarts[i + 1] : null;
      if (end == null) continue;
      longestStint = (end - stintStarts[i]) > longestStint ? end - stintStarts[i] : longestStint;
    }

    return 'Tires showed ${tireWearEstimate.consecutiveDegradingLaps} consecutive laps of '
        'real degradation in practice (${tireWearEstimate.percentSlowerThanStintBest!.toStringAsFixed(1)}% '
        'off the stint best) -- the longest planned stint ($longestStint laps) may be too long '
        'for this compound; consider a shorter stint than the plan currently assumes.';
  }
}
