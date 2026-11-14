import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/services/practice_fuel_calculator.dart';

PracticeLapRecord _lap(double used, {int shortShifts = 0, int good = 0, int overRevs = 0, bool pit = false}) =>
    PracticeLapRecord(
      lapNumber: 1,
      lapTimeMs: 90000,
      tireCompound: 'Racing Medium',
      fuelPercentAtLapStart: 50,
      fuelPercentAtLapEnd: 50 - used,
      shortShiftCount: shortShifts,
      goodShiftCount: good,
      overRevShiftCount: overRevs,
      recordedAt: DateTime(2026),
      isPitLap: pit,
    );

void main() {
  test('a plain average of every logged lap', () {
    expect(PracticeFuelCalculator.averagePercentPerLap([_lap(3), _lap(4), _lap(5)]), 4.0);
  });

  test('shift quality has no effect: short-shifted and over-revved laps count like any other', () {
    final laps = [_lap(3, good: 8), _lap(5, shortShifts: 8), _lap(4, overRevs: 8)];
    expect(PracticeFuelCalculator.averagePercentPerLap(laps), 4.0);
    expect(PracticeFuelCalculator.usableLaps(laps), hasLength(3));
  });

  test('pit laps and refuel laps (negative use) are left out', () {
    expect(PracticeFuelCalculator.averagePercentPerLap([_lap(3), _lap(5), _lap(-30), _lap(9, pit: true)]), 4.0);
  });

  test('needs at least 2 usable laps', () {
    expect(PracticeFuelCalculator.averagePercentPerLap([_lap(3)]), isNull);
    expect(PracticeFuelCalculator.averagePercentPerLap([_lap(3), _lap(3, pit: true)]), isNull);
    expect(PracticeFuelCalculator.averagePercentPerLap(const []), isNull);
  });
}
