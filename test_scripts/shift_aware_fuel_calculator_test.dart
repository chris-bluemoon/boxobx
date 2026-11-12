// Standalone validation for ShiftAwareFuelCalculator: computes a
// fuel-per-lap average WEIGHTED by shift quality, excluding laps with
// a lot of short-shifting/over-revving (which burn more fuel than a
// clean lap would for the same distance), so practice-session fuel
// predictions aren't biased toward the driver's worst shift habits.
//
// Run with: dart run test_scripts/shift_aware_fuel_calculator_test.dart
import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/services/shift_aware_fuel_calculator.dart';

void check(String label, bool condition) {
  print('${condition ? "PASS" : "FAIL"} $label');
  if (!condition) throw Exception('Failed: $label');
}

PracticeLapRecord lapWith({
  required double fuelConsumed,
  int shortShifts = 0,
  int goodShifts = 10,
  int overRevShifts = 0,
}) {
  return PracticeLapRecord(
    lapNumber: 1,
    lapTimeMs: 90000,
    tireCompound: 'Racing Hard',
    fuelPercentAtLapStart: 100,
    fuelPercentAtLapEnd: 100 - fuelConsumed,
    shortShiftCount: shortShifts,
    goodShiftCount: goodShifts,
    overRevShiftCount: overRevShifts,
    recordedAt: DateTime.now(),
  );
}

void main() {
  // --- Not enough clean laps yet (fewer than the minimum sample size) ---
  final tooFewLaps = [lapWith(fuelConsumed: 5.0)];
  check(
    'returns null with fewer than the minimum clean-lap count',
    ShiftAwareFuelCalculator.averagePercentPerLap(tooFewLaps) == null,
  );

  // --- Enough clean laps: a straightforward average of clean laps only ---
  final cleanLaps = [
    lapWith(fuelConsumed: 5.0, goodShifts: 10),
    lapWith(fuelConsumed: 5.2, goodShifts: 10),
    lapWith(fuelConsumed: 4.8, goodShifts: 10),
  ];
  final cleanAverage = ShiftAwareFuelCalculator.averagePercentPerLap(cleanLaps);
  check('computes a non-null average once enough clean laps exist', cleanAverage != null);
  check('the average is correct for all-clean laps', (cleanAverage! - 5.0).abs() < 0.001);

  // --- A dirty lap (lots of short-shifts/over-revs) is EXCLUDED from
  // the average, not just down-weighted -- its inflated fuel use
  // shouldn't drag the "clean" prediction toward a pessimistic number. ---
  final mixedLaps = [
    lapWith(fuelConsumed: 5.0, goodShifts: 10),
    lapWith(fuelConsumed: 5.0, goodShifts: 10),
    // A dirty lap: mostly short-shifts, burns noticeably more fuel.
    lapWith(fuelConsumed: 8.0, shortShifts: 8, goodShifts: 2),
  ];
  final mixedAverage = ShiftAwareFuelCalculator.averagePercentPerLap(mixedLaps);
  check('the dirty lap is excluded -- average reflects only the 2 clean laps', mixedAverage != null && (mixedAverage! - 5.0).abs() < 0.001);

  // --- A lap with NO recorded shifts at all is treated as clean
  // (neither penalized nor specially trusted), not excluded. ---
  final noShiftDataLaps = [
    lapWith(fuelConsumed: 5.0, goodShifts: 10),
    lapWith(fuelConsumed: 5.2, shortShifts: 0, goodShifts: 0, overRevShifts: 0), // no shift data at all
  ];
  final noShiftAverage = ShiftAwareFuelCalculator.averagePercentPerLap(noShiftDataLaps);
  check(
    'a lap with no shift data at all is included (not excluded) in the average',
    noShiftAverage != null && (noShiftAverage! - 5.1).abs() < 0.001,
  );

  // --- cleanLapCount reports how many of ALL laps (not just the
  // qualifying ones) were clean enough, for UI display. ---
  check(
    'cleanLapCount reports 2 clean laps out of 3 total (mixedLaps)',
    ShiftAwareFuelCalculator.cleanLapCount(mixedLaps) == 2,
  );
  check(
    'cleanLapCount is 0 when no laps are clean enough',
    ShiftAwareFuelCalculator.cleanLapCount([lapWith(fuelConsumed: 8.0, shortShifts: 9, goodShifts: 1)]) == 0,
  );

  // --- An empty lap list returns null gracefully, not a crash ---
  check('returns null for an empty lap list', ShiftAwareFuelCalculator.averagePercentPerLap([]) == null);

  print('\nAll ShiftAwareFuelCalculator checks passed.');
}
