// The brief's minimum pit stops, and the fuel map: Map 1 until a leaner
// map has been measured, picked only when it saves a stop above the
// minimum -- and put up for a stint test when it might.
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/models/race_strategy.dart';
import 'package:boxbox/models/test_plan.dart';
import 'package:boxbox/services/fuel_map_measurement.dart';
import 'package:boxbox/services/pit_stop_calculator.dart';
import 'package:boxbox/services/stint_summary.dart';
import 'package:boxbox/services/test_plan_tracker.dart';

RaceBriefing _brief({int minStops = 0, String weather = '', int laps = 13}) => RaceBriefing(
  trackName: 'Sainte-Croix C',
  totalLaps: laps,
  startingFuelPercent: 100,
  fuelConsumptionMultiplier: 4,
  availableTireCompounds: const ['Racing Hard', 'Racing Soft', 'Intermediate', 'Heavy Wet'],
  mandatoryPitStopCount: minStops,
  weatherSlots: weather,
);

PracticeLapRecord _lap(int n, {int? map, double used = 20.0, int ms = 224000, double fuelStart = 100}) => PracticeLapRecord(
  lapNumber: n,
  lapTimeMs: ms,
  tireCompound: 'Racing Hard',
  fuelPercentAtLapStart: fuelStart,
  fuelPercentAtLapEnd: fuelStart - used,
  recordedAt: DateTime(2026),
  stintNumber: map == null ? 1 : 2,
  testNumber: map == null ? 1 : 3,
  fuelMap: map,
);

void main() {
  // 20% a lap on Map 1: 4 laps a tank (5% kept back), 3 stops -- Map 2's
  // 12% saving makes it 5 laps.
  RaceStrategy strategyFor(int minStops, {Map<int, FuelMapMeasurement> maps = const {}}) =>
      PitStopCalculator.calculate(_brief(minStops: minStops), measuredPercentPerLap: 20.0, lapTimeSeconds: 224, measuredMaps: maps);

  test('nothing measured on a leaner map: Map 1, and Map 2 put up for a test', () {
    final plan = strategyFor(0);
    expect(plan.fuelMap, 1);
    expect(plan.pitStops, hasLength(3));
    expect(plan.fuelMapToTest, 2);
  });

  test('Map 2 measured saving 12% for 0.6% a lap: saves a stop and is worth it', () {
    final laps = [
      for (var n = 1; n <= 4; n++) _lap(n, fuelStart: 100 - (n - 1) * 20.0),
      for (var n = 5; n <= 7; n++) _lap(n, map: 2, used: 20.0 * 0.88, ms: 225300, fuelStart: 100 - (n - 5) * 17.6),
    ];
    final maps = FuelMapMeasurement.fromLaps(laps);
    expect(maps[2]!.fuelFactor, closeTo(0.88, 0.001));
    expect(maps[2]!.lapTimeLoss, closeTo(0.0058, 0.0005));
    final plan = strategyFor(0, maps: maps);
    // 2 stops: stints of 4, 5 and 4 laps -- Map 2 only for the 5-lap one.
    expect(plan.pitStops, hasLength(2));
    expect(plan.stintMaps, [1, 2, 1]);
    expect([for (final p in plan.pitStops) p.lap], [4, 9]);
    expect(plan.fuelMapToTest, isNull);
    expect(plan.basis[1], contains('measured over 3 laps'));
    // Plan B, the quicker alternative: Softs then Hards on the same 2
    // stops. Plan C: the extra stop, no fuel saving.
    expect(plan.planB!.stintTyres.toSet(), {'Racing Soft', 'Racing Hard'});
    expect(plan.planB!.pitStops, hasLength(2));
    final c = plan.planC!;
    expect(c.pitStops, hasLength(3));
    expect(c.stintMaps, [1, 1, 1, 1]);
    expect(c.summary, contains('1 stop more, no fuel saving'));
    expect(plan.planB!.secondsBehindPlanA, lessThan(c.secondsBehindPlanA!));
  });

  test('a minimum of 3 stops: a fuel map saves nothing, so Map 1 and no test', () {
    final plan = strategyFor(3);
    expect(plan.fuelMap, 1);
    expect(plan.pitStops, hasLength(3));
    expect(plan.fuelMapToTest, isNull);
  });

  test('a minimum above what fuel needs adds stops, and says so', () {
    final plan = strategyFor(4);
    expect(plan.pitStops, hasLength(4));
    expect(plan.basis.join(' '), contains('requires 4 stops'));
  });

  test('the test plan gets a Map 2 stint, and it keeps its map', () {
    final plan = TestPlan.fromBriefing(_brief(), startCompound: 'Racing Hard', fuelPerLapPercent: 20.0, fuelMapToTest: 2);
    final test = plan.stints.firstWhere((s) => s.kind == TestStintKind.fuelMap);
    expect(test.target, 'Hard · 100% fuel · Map 2 · 3 laps');
    expect(plan.stints.where((s) => s.kind != TestStintKind.fuelMap).map((s) => s.fuelMap).toSet(), {1});
    expect(TestPlan.fuelMapTested([_lap(1, map: 2)]), 2);
  });

  test("the fuel map test's 3 laps complete it, and the quickest isn't off pace (19 Nov)", () {
    final plan = TestPlan.fromBriefing(_brief(), startCompound: 'Racing Hard', fuelPerLapPercent: 20.0, fuelMapToTest: 2);
    final test = plan.stints.firstWhere((s) => s.kind == TestStintKind.fuelMap);
    final laps = [
      for (final (i, ms) in [223948, 223789, 222770].indexed) _lap(i + 1, map: 2, ms: ms, fuelStart: 98.3 - i * 17.2),
    ];
    final stint = StintSummary.fromLaps(laps).single;
    expect(stint.excludedLaps, isEmpty);
    expect(stint.bestLapMs, 222770);
    expect(TestPlanTracker.stopReason(test, stint), '3 laps done');
  });

  test("a 3:40 lap 1.1 s off a steep fuel-burn trend isn't off pace (19 Nov)", () {
    final laps = [
      for (final (i, ms) in [221392, 221839, 220140, 219462].indexed) _lap(i + 1, ms: ms, fuelStart: 98.2 - i * 19.3),
    ];
    expect(StintSummary.fromLaps(laps).single.excludedLaps, isEmpty);
    // A real moment (a spin's worth) still is.
    final spun = [
      for (final (i, ms) in [221392, 229000, 220140, 219462].indexed) _lap(i + 1, ms: ms, fuelStart: 98.2 - i * 19.3),
    ];
    expect(StintSummary.fromLaps(spun).single.excludedLaps.map((l) => l.lapTimeMs), [229000]);
    // ...and a long stint still ends at its laps with that lap in them.
    final plan = TestPlan.fromBriefing(_brief(), startCompound: 'Racing Hard', fuelPerLapPercent: 19.3);
    final long = plan.stints.first;
    expect(long.laps, 4);
    expect(TestPlanTracker.stopReason(long, StintSummary.fromLaps(spun).single), 'a full tank done (4 laps)');
  });

  test('a wet plan meets the minimum too: extra stops halfway through the longest stint', () {
    final none = PitStopCalculator.calculate(_brief(weather: 'R06/R05', laps: 10), measuredPercentPerLap: 5);
    final withMin = PitStopCalculator.calculate(_brief(weather: 'R06/R05', laps: 10, minStops: 1), measuredPercentPerLap: 5);
    expect(none.pitStops, isEmpty);
    expect(withMin.pitStops, hasLength(1));
    expect(withMin.pitStops.single.lap, inInclusiveRange(2, 9));
    expect(withMin.pitStops.single.tireCompound, withMin.startingTireCompound);
    expect(withMin.basis.join(' '), contains('requires 1 stop'));
  });
}
