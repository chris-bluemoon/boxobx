// Standalone validation for TireWearTracker: the lap-time-degradation
// proxy for tire wear (GT7's telemetry packet has no real tire-wear
// field at all, so lap-time degradation within a stint is used
// instead).
//
// Run with: dart run test_scripts/tire_wear_tracker_test.dart
import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/services/tire_wear_tracker.dart';

void check(String label, bool condition) {
  print('${condition ? "PASS" : "FAIL"} $label');
  if (!condition) throw Exception('Failed: $label');
}

TelemetryFrame frameFor({required int lap, required int lastLapTimeMs}) => TelemetryFrame(
      rpm: 6000,
      speedKmh: 200,
      gear: 4,
      posX: 0,
      posY: 0,
      posZ: 0,
      lapDistance: 0,
      trackLength: 0,
      fuelPercent: 80,
      tireTemps: const [90, 90, 90, 90],
      currentLap: lap,
      lastLapTimeMs: lastLapTimeMs,
    );

void main() {
  // --- No data yet before any lap completes ---
  final tracker1 = TireWearTracker();
  final beforeAnyLap = tracker1.update(frameFor(lap: 1, lastLapTimeMs: -1));
  check('no estimate before any lap has completed', !beforeAnyLap.hasEnoughData);

  // --- First completed lap establishes the stint baseline (0% slower) ---
  final afterLap1 = tracker1.update(frameFor(lap: 2, lastLapTimeMs: 90000)); // 1:30.000
  check('first completed lap has enough data', afterLap1.hasEnoughData);
  check('first completed lap is 0% slower (it IS the stint best)', afterLap1.percentSlowerThanStintBest == 0.0);
  check('first completed lap has 0 consecutive degrading laps', afterLap1.consecutiveDegradingLaps == 0);

  // --- A meaningfully slower second lap counts as 1 degrading lap ---
  final afterLap2 = tracker1.update(frameFor(lap: 3, lastLapTimeMs: 91500)); // ~1.67% slower
  check('a meaningfully slower lap reports a positive percentSlowerThanStintBest', afterLap2.percentSlowerThanStintBest! > 0);
  check('a meaningfully slower lap counts as 1 consecutive degrading lap', afterLap2.consecutiveDegradingLaps == 1);

  // --- A further slower lap increments the degrading streak ---
  final afterLap3 = tracker1.update(frameFor(lap: 4, lastLapTimeMs: 93000)); // further slower
  check('a second consecutive slower lap increments the degrading streak to 2', afterLap3.consecutiveDegradingLaps == 2);

  // --- A faster lap (new stint best) resets the degrading streak ---
  final afterLap4 = tracker1.update(frameFor(lap: 5, lastLapTimeMs: 89000)); // new best
  check('a new stint-best lap resets percentSlowerThanStintBest to 0', afterLap4.percentSlowerThanStintBest == 0.0);
  check('a new stint-best lap resets the degrading streak to 0', afterLap4.consecutiveDegradingLaps == 0);

  // --- A lap within noise threshold doesn't count as degrading ---
  final tracker2 = TireWearTracker();
  tracker2.update(frameFor(lap: 1, lastLapTimeMs: -1));
  tracker2.update(frameFor(lap: 2, lastLapTimeMs: 90000));
  final tinyVariance = tracker2.update(frameFor(lap: 3, lastLapTimeMs: 90050)); // 0.055% slower, below threshold
  check('a lap within the noise threshold does not count as degrading', tinyVariance.consecutiveDegradingLaps == 0);

  // --- reset() clears everything (simulating a pit stop for tires) ---
  tracker2.reset();
  final afterReset = tracker2.update(frameFor(lap: 10, lastLapTimeMs: -1));
  check('reset() clears tracked history', !afterReset.hasEnoughData);

  // --- A lap-count jump (session restart) resets history automatically ---
  final tracker3 = TireWearTracker();
  tracker3.update(frameFor(lap: 1, lastLapTimeMs: -1));
  tracker3.update(frameFor(lap: 2, lastLapTimeMs: 90000));
  tracker3.update(frameFor(lap: 3, lastLapTimeMs: 92000)); // degrading
  final afterJump = tracker3.update(frameFor(lap: 1, lastLapTimeMs: -1)); // lap count went backwards
  check('a lap-count jump/reset clears degradation history automatically', !afterJump.hasEnoughData);

  print('\nAll TireWearTracker checks passed.');
}
