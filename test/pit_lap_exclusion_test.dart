import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/services/practice_fuel_calculator.dart';
import 'package:boxbox/services/tire_wear_tracker.dart';

TelemetryFrame _frame(int lap, int lastLapTimeMs) => TelemetryFrame(
  rpm: 0,
  speedKmh: 0,
  gear: 0,
  posX: 0,
  posY: 0,
  posZ: 0,
  lapDistance: 0,
  trackLength: 0,
  fuelPercent: 50,
  tireTemps: const [0, 0, 0, 0],
  currentLap: lap,
  lastLapTimeMs: lastLapTimeMs,
);

PracticeLapRecord _lap(double start, double end, {bool pit = false}) => PracticeLapRecord(
  lapNumber: 1,
  lapTimeMs: 90000,
  tireCompound: 'Racing Medium',
  fuelPercentAtLapStart: start,
  fuelPercentAtLapEnd: end,
  recordedAt: DateTime(2026),
  isPitLap: pit,
);

void main() {
  test('TireWearTracker ignores an excluded pit lap instead of counting it as degradation', () {
    // lastLapTimeMs at the N -> N+1 boundary is lap N's time.
    final withExclusion = TireWearTracker()..excludeLaps({2});
    final withoutExclusion = TireWearTracker();
    for (final tracker in [withExclusion, withoutExclusion]) {
      tracker.update(_frame(1, -1));
      tracker.update(_frame(2, 90000)); // lap 1: 90.0s (stint best)
      tracker.update(_frame(3, 120000)); // lap 2: pit lap, 120s
    }
    expect(withoutExclusion.update(_frame(3, 120000)).consecutiveDegradingLaps, 1);
    expect(withExclusion.update(_frame(3, 120000)).consecutiveDegradingLaps, 0);
    expect(withExclusion.update(_frame(3, 120000)).percentSlowerThanStintBest, 0);
  });

  test('PracticeFuelCalculator leaves pit laps out of the fuel average', () {
    final laps = [_lap(100, 97), _lap(97, 94), _lap(64, 94, pit: true)];
    expect(PracticeFuelCalculator.averagePercentPerLap(laps), 3.0);
    expect(PracticeFuelCalculator.usableLaps(laps), hasLength(2));
  });

  test('isPitLap survives persistence and defaults to false for old records', () {
    final restored = PracticeLapRecord.fromMap(_lap(1, 0, pit: true).toMap());
    expect(restored.isPitLap, isTrue);
    expect(restored.withLapNumber(4).isPitLap, isTrue);
    final legacy = _lap(1, 0).toMap()..remove('isPitLap');
    expect(PracticeLapRecord.fromMap(legacy).isPitLap, isFalse);
  });
}
