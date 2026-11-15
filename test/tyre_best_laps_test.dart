import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/models/time_trial_lap.dart';
import 'package:boxbox/services/tyre_best_laps.dart';

PracticeLapRecord _lap(int n, int ms, String tyre, {int stint = 1, bool pit = false, String? weather, double? water}) =>
    PracticeLapRecord(
      lapNumber: n,
      lapTimeMs: ms,
      tireCompound: tyre,
      fuelPercentAtLapStart: 100 - n * 3.0,
      fuelPercentAtLapEnd: 97 - n * 3.0,
      recordedAt: DateTime(2026, 11, 15, 10, n),
      stintNumber: stint,
      isPitLap: pit,
      weather: weather,
      waterPercent: water,
    );

void main() {
  test('best and average clean dry lap per tyre, quickest tyre first, with the time-trial best', () {
    final laps = [
      for (var i = 0; i < 5; i++) _lap(i + 1, 90000 + i * 100, 'Racing Medium'),
      for (var i = 0; i < 5; i++) _lap(i + 6, 89500 + i * 100, 'Racing Soft', stint: 2),
      _lap(11, 85000, 'Racing Soft', stint: 2, pit: true), // a pit lap never counts
      for (var i = 0; i < 3; i++) _lap(i + 12, 88000, 'Racing Soft', stint: 3, weather: 'R05'), // wet
      for (var i = 0; i < 3; i++) _lap(i + 15, 88000, 'Racing Hard', stint: 4, water: 40), // wet by the gauge
    ];
    final tt = [TimeTrialLap(lapTimeMs: 89000, tireCompound: 'Racing Soft', recordedAt: DateTime(2026, 11, 15))];
    final result = TyreBestLap.fromLaps(laps, timeTrial: tt);
    expect(result.map((t) => t.compound), ['Racing Soft', 'Racing Medium']);
    final soft = result.first;
    expect(soft.bestMs, 89500);
    expect(soft.averageMs, 89700);
    expect(soft.laps, 5);
    expect(soft.timeTrialMs, 89000);
    expect(result.last.bestMs, 90000);
    expect(result.last.timeTrialMs, isNull);
  });

  test('a tyre run only in time trial still shows', () {
    final tt = [TimeTrialLap(lapTimeMs: 88000, tireCompound: 'Racing Hard', recordedAt: DateTime(2026, 11, 15))];
    final result = TyreBestLap.fromLaps(const [], timeTrial: tt);
    expect(result.single.compound, 'Racing Hard');
    expect(result.single.bestMs, isNull);
    expect(result.single.laps, 0);
  });
}
