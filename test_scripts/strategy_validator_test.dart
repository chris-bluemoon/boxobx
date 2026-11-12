// Standalone validation for StrategyValidator: the logic comparing a
// RaceStrategy's assumed fuel consumption against real practice-session
// telemetry (FuelPrediction), feeding the new Race Strategy screen's
// "VALIDATE AGAINST PRACTICE SESSION" button.
//
// Run with: dart run test_scripts/strategy_validator_test.dart
import 'package:boxbox/models/fuel_prediction.dart';
import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/models/race_strategy.dart';
import 'package:boxbox/models/strategy_validation.dart';
import 'package:boxbox/models/tire_wear_estimate.dart';
import 'package:boxbox/services/strategy_validator.dart';

void check(String label, bool condition) {
  print('${condition ? "PASS" : "FAIL"} $label');
  if (!condition) throw Exception('Failed: $label');
}

RaceBriefing briefingWith({required double startingFuelPercent}) {
  return RaceBriefing(
    trackName: 'Test Circuit',
    totalLaps: 20,
    startingFuelPercent: startingFuelPercent,
    availableTireCompounds: const ['Racing Hard', 'Racing Medium'],
  );
}

RaceStrategy strategyWith({required double assumedPercentPerLap}) {
  return RaceStrategy(
    pitStops: const [],
    startingTireCompound: 'Racing Medium',
    summary: 'Test strategy',
    assumedPercentPerLap: assumedPercentPerLap,
  );
}

void main() {
  final validator = StrategyValidator();

  // --- Insufficient practice data ---
  final result1 = validator.evaluate(
    strategy: strategyWith(assumedPercentPerLap: 5.0),
    briefing: briefingWith(startingFuelPercent: 100),
    practiceFuelPrediction: FuelPrediction.insufficientData(),
  );
  check('insufficient practice data reports insufficientData fitness', result1.fitness == StrategyFitness.insufficientData);
  check('insufficientData carries the strategy\'s assumed value through for display', result1.assumedPercentPerLap == 5.0);

  // --- Real consumption close to assumption (within 15%) -> on plan ---
  final result2 = validator.evaluate(
    strategy: strategyWith(assumedPercentPerLap: 5.0),
    briefing: briefingWith(startingFuelPercent: 100),
    practiceFuelPrediction: const FuelPrediction(
      predictedEmptyLap: 20,
      percentPerLap: 5.3, // 6% higher, within the 15% threshold
      hasEnoughData: true,
    ),
  );
  check('a small difference within threshold reports onPlan', result2.fitness == StrategyFitness.onPlan);
  check('onPlan does not produce a recommended pit lap (no change needed)', result2.recommendedPitLap == null);

  // --- Burning significantly MORE than planned ---
  final result3 = validator.evaluate(
    strategy: strategyWith(assumedPercentPerLap: 5.0),
    briefing: briefingWith(startingFuelPercent: 100),
    practiceFuelPrediction: const FuelPrediction(
      predictedEmptyLap: 15,
      percentPerLap: 7.0, // 40% higher -- well past the threshold
      hasEnoughData: true,
    ),
  );
  check('burning significantly more fuel reports burningMoreThanPlanned', result3.fitness == StrategyFitness.burningMoreThanPlanned);
  check(
    'recommends an earlier pit lap recalculated from real consumption (100/7.0 = 14)',
    result3.recommendedPitLap == 14,
  );

  // --- Burning significantly LESS than planned ---
  final result4 = validator.evaluate(
    strategy: strategyWith(assumedPercentPerLap: 5.0),
    briefing: briefingWith(startingFuelPercent: 100),
    practiceFuelPrediction: const FuelPrediction(
      predictedEmptyLap: 30,
      percentPerLap: 3.0, // 40% lower
      hasEnoughData: true,
    ),
  );
  check('burning significantly less fuel reports burningLessThanPlanned', result4.fitness == StrategyFitness.burningLessThanPlanned);
  check(
    'recommends a later pit lap recalculated from real consumption (100/3.0 = 33)',
    result4.recommendedPitLap == 33,
  );

  // --- Non-positive assumed consumption (malformed AI response) ---
  final result5 = validator.evaluate(
    strategy: strategyWith(assumedPercentPerLap: 0.0),
    briefing: briefingWith(startingFuelPercent: 100),
    practiceFuelPrediction: const FuelPrediction(
      predictedEmptyLap: 20,
      percentPerLap: 5.0,
      hasEnoughData: true,
    ),
  );
  check(
    'a non-positive assumed value reports insufficientData rather than dividing by zero',
    result5.fitness == StrategyFitness.insufficientData,
  );

  // --- Real tire degradation signal present -> tireWearWarning populated ---
  final strategyWithStops = RaceStrategy(
    pitStops: const [
      PlannedPitStop(lap: 10, tireCompound: 'Racing Hard', reasoning: 'x'),
      PlannedPitStop(lap: 20, tireCompound: 'Racing Medium', reasoning: 'x'),
    ],
    startingTireCompound: 'Racing Hard',
    summary: 'Test strategy',
    assumedPercentPerLap: 5.0,
  );
  final result6 = validator.evaluate(
    strategy: strategyWithStops,
    briefing: briefingWith(startingFuelPercent: 100),
    practiceFuelPrediction: const FuelPrediction(
      predictedEmptyLap: 20,
      percentPerLap: 5.0,
      hasEnoughData: true,
    ),
    tireWearEstimate: const TireWearEstimate(
      percentSlowerThanStintBest: 2.1,
      consecutiveDegradingLaps: 4,
      hasEnoughData: true,
    ),
  );
  check('a real degradation streak produces a non-null tireWearWarning', result6.tireWearWarning != null);
  check('the tireWearWarning mentions the longest planned stint length (10 laps)', result6.tireWearWarning!.contains('10 laps'));

  // --- Degradation below the warning threshold (1-2 laps) -> no warning ---
  final result7 = validator.evaluate(
    strategy: strategyWithStops,
    briefing: briefingWith(startingFuelPercent: 100),
    practiceFuelPrediction: const FuelPrediction(
      predictedEmptyLap: 20,
      percentPerLap: 5.0,
      hasEnoughData: true,
    ),
    tireWearEstimate: const TireWearEstimate(
      percentSlowerThanStintBest: 0.8,
      consecutiveDegradingLaps: 1,
      hasEnoughData: true,
    ),
  );
  check('a short (below-threshold) degradation streak does not produce a warning', result7.tireWearWarning == null);

  // --- No tire wear data at all -> no warning, doesn't affect fuel fitness ---
  final result8 = validator.evaluate(
    strategy: strategyWithStops,
    briefing: briefingWith(startingFuelPercent: 100),
    practiceFuelPrediction: const FuelPrediction(
      predictedEmptyLap: 20,
      percentPerLap: 5.0,
      hasEnoughData: true,
    ),
  );
  check('omitting tireWearEstimate entirely still works and produces no warning', result8.tireWearWarning == null);
  check('fuel fitness is unaffected by the absence of tire wear data', result8.fitness == StrategyFitness.onPlan);

  print('\nAll StrategyValidator checks passed.');
}
