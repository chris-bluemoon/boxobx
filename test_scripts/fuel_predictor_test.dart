// Standalone validation for FuelPredictor: the lap-detection and
// rolling-average consumption logic that drives the new "PIT LAP"
// dashboard prediction (replacing the raw fuel% card, which just
// duplicated what GT7's own HUD already shows).
//
// Run with: dart run test_scripts/fuel_predictor_test.dart
import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/services/fuel_predictor.dart';

void check(String label, bool condition) {
  print('${condition ? "PASS" : "FAIL"} $label');
  if (!condition) throw Exception('Failed: $label');
}

TelemetryFrame frameWith({required int lap, required double fuelPercent}) {
  return TelemetryFrame(
    rpm: 7000,
    speedKmh: 200,
    gear: 5,
    posX: 0,
    posY: 0,
    posZ: 0,
    lapDistance: 0,
    trackLength: 0,
    fuelPercent: fuelPercent,
    tireTemps: const [90, 90, 90, 90],
    currentLap: lap,
    totalLaps: 20,
  );
}

void main() {
  // --- No data yet ---
  final predictor = FuelPredictor();
  final first = predictor.update(frameWith(lap: 1, fuelPercent: 100));
  check('no prediction on the very first frame (no completed lap yet)', !first.hasEnoughData);

  // --- Steady consumption: 10% per lap ---
  // The lap-transition frame itself is exactly when consumption for the
  // lap that just ended becomes known, so a prediction becomes
  // available immediately on that same frame (not one frame later).
  predictor.update(frameWith(lap: 1, fuelPercent: 90));
  final afterLap1Transition = predictor.update(frameWith(lap: 2, fuelPercent: 90));
  check(
    'prediction becomes available on the lap-2 transition frame itself',
    afterLap1Transition.hasEnoughData,
  );
  check(
    'percentPerLap is ~10 after one 10%-consumption lap',
    (afterLap1Transition.percentPerLap! - 10.0).abs() < 0.01,
  );
  // 90% remaining at lap 2 / 10%-per-lap = 9 laps left -> empty at lap 2+9=11
  check('predicts empty lap correctly', afterLap1Transition.predictedEmptyLap == 11);

  // --- Averaging over multiple laps ---
  // Baseline at lap-2 start was already set to 90 (by the lap-2
  // transition frame above) -- lap 2 then consumes down to 80, and the
  // lap-3 transition frame records that as this lap's consumption.
  final afterLap2Transition = predictor.update(frameWith(lap: 3, fuelPercent: 80));
  // lap 1->2 consumed 10%, lap 2->3 consumed 10% (90 -> 80) -- average of [10, 10] = 10
  check(
    'rolling average updates correctly across laps',
    (afterLap2Transition.percentPerLap! - 10.0).abs() < 0.01,
  );

  // --- Session restart (lap count resets) clears history ---
  final restarted = predictor.update(frameWith(lap: 1, fuelPercent: 100));
  check('session restart (lap count drops) resets to no prediction', !restarted.hasEnoughData);

  // --- A refuel (fuel increases instead of decreasing) is not recorded
  // as negative consumption -- the lap spanning the refuel is simply
  // skipped/ignored, and tracking resumes cleanly on the next lap.
  final predictor2 = FuelPredictor();
  predictor2.update(frameWith(lap: 1, fuelPercent: 50));
  // Lap 1->2 transition spans a pit stop refuel: fuel went UP, not down.
  final acrossRefuel = predictor2.update(frameWith(lap: 2, fuelPercent: 100));
  check(
    'the refuel lap itself is not recorded as a (negative) consumption sample',
    !acrossRefuel.hasEnoughData,
  );
  // Next lap burns normally from the post-refuel baseline (100% at lap 2 start).
  predictor2.update(frameWith(lap: 2, fuelPercent: 85));
  final afterNormalLap = predictor2.update(frameWith(lap: 3, fuelPercent: 85));
  check(
    'tracking resumes normally on the lap after a refuel',
    afterNormalLap.hasEnoughData && (afterNormalLap.percentPerLap! - 15.0).abs() < 0.01,
  );

  print('\nAll FuelPredictor checks passed.');
}
