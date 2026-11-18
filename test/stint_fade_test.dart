// Tyres fading at the end of a stint count as the tyres going off, not
// as laps off the pace.
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/services/stint_summary.dart';

// 16 Nov AI race, the last stint on Inters: the pace fading with the
// tyres to the flag, the last lap on 25% left -- it was being left out
// as off pace.
PracticeLapRecord _fadeLap(int n, int ms, double wear, {List<int>? spins}) => PracticeLapRecord(
      lapNumber: n,
      lapTimeMs: ms,
      tireCompound: 'Intermediate',
      fuelPercentAtLapStart: 50,
      fuelPercentAtLapEnd: 46,
      tireWearPercent: wear,
      recordedAt: DateTime(2026, 11, 16, 16, n),
      stintNumber: 46,
      spinCorners: spins,
    );

List<PracticeLapRecord> _stint46({List<int>? lastLapSpins}) => [
      _fadeLap(110, 104800, 98),
      _fadeLap(111, 103100, 87),
      _fadeLap(112, 101400, 84),
      _fadeLap(113, 99600, 80),
      _fadeLap(114, 97500, 78),
      _fadeLap(115, 95800, 69),
      _fadeLap(116, 95700, 60),
      _fadeLap(117, 95800, 48),
      _fadeLap(118, 96200, 36),
      _fadeLap(119, 97200, 25, spins: lastLapSpins),
    ];


void main() {
  test('the last lap on worn tyres counts -- the pace never came back', () {
    final stint = StintSummary.fromLaps(_stint46()).single;
    expect(stint.excludedLaps.map((l) => l.lapNumber), isNot(contains(119)));
  });

  test('a slow lap the pace comes back from is still a mistake', () {
    final laps = [
      for (var n = 1; n <= 8; n++) _fadeLap(n, n == 4 ? 95500 : 92500 - n * 50, 95 - n * 2.0),
    ];
    expect(StintSummary.fromLaps(laps).single.excludedLaps.map((l) => l.lapNumber), [4]);
  });

  test('a spin on that last lap is still left out', () {
    final stint = StintSummary.fromLaps(_stint46(lastLapSpins: const [3])).single;
    expect(stint.excludedLaps.map((l) => l.lapNumber), contains(119));
  });
}
