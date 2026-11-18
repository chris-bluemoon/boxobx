// A wet brief's strategy follows the weather: tyre stops where it turns
// wet or dry, fuel at the same stops -- and it's starred until the
// practice stint tests are done.
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/models/race_strategy.dart';
import 'package:boxbox/models/weather_forecast.dart';
import 'package:boxbox/screens/race_strategy_screen.dart';
import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/services/pit_stop_calculator.dart';
import 'package:boxbox/services/strategy_changes.dart';
import 'package:boxbox/services/wet_pace_table.dart';

RaceBriefing _brief(String weather, {int laps = 26, double fuel = 100}) => RaceBriefing(
  trackName: 'Test',
  totalLaps: laps,
  startingFuelPercent: fuel,
  availableTireCompounds: const ['Racing Hard', 'Racing Medium', 'Racing Soft', 'Intermediate', 'Heavy Wet'],
  weatherSlots: weather,
);

void main() {
  test('R06/R05/C03/S14/S04/R03/R04/R05 over 26 laps: Inters, Hards about lap 8, Inters about lap 17', () {
    final plan = PitStopCalculator.calculate(_brief('R06/R05/C03/S14/S04/R03/R04/R05'));
    // R06 (Wets, laps 1-3) then R05 (Inters, 4-7) is one wet spell on the
    // tyre covering more of it -- no extra Wets -> Inters stop.
    expect(plan.startingTireCompound, 'Intermediate');
    expect([for (final s in plan.pitStops) '${s.lap} ${s.tireCompound}'], ['8 Racing Hard', '17 Intermediate']);
    expect(plan.summary, contains('water gauge'));
  });

  test('a mostly-wet opening on Wets starts on Wets', () {
    final plan = PitStopCalculator.calculate(_brief('R07/R06/R04/C02', laps: 20));
    expect(plan.startingTireCompound, 'Heavy Wet');
    expect([for (final s in plan.pitStops) s.tireCompound], ['Racing Hard']);
  });

  test('a wet spell longer than a tank gets a fuel stop on the same tyre', () {
    // 2.5%/lap at 1x, half a lap (1.25%) kept back: 50% fuel lasts 19 laps.
    final plan = PitStopCalculator.calculate(_brief('R05', laps: 30, fuel: 50), measuredPercentPerLap: 2.5);
    expect(plan.startingTireCompound, 'Intermediate');
    expect([for (final s in plan.pitStops) '${s.lap} ${s.tireCompound}'], ['20 Intermediate']);
  });

  test('a dry brief (or light rain only) keeps the fuel plan', () {
    final plan = PitStopCalculator.calculate(_brief('C01/R02/S03'));
    expect(plan.pitStops.every((s) => !s.tireCompound.contains('Inter') && !s.tireCompound.contains('Wet')), isTrue);
  });

  test('starred until every practice stint test is done', () {
    final plan = PitStopCalculator.calculate(_brief('R06/R05/C03/S14/S04/R03/R04/R05'));
    expect(plan.validatedByPractice, isFalse);
    final some = plan.withPractice(done: 2, planned: 6);
    expect(some.validatedByPractice, isFalse);
    expect(RaceStrategyScreen.notValidatedNote(some), contains('2 of 6 stint tests done'));
    final all = RaceStrategy.fromMap(plan.withPractice(done: 6, planned: 6).toMap());
    expect(all.validatedByPractice, isTrue, reason: 'kept through saving');
  });

  test('more weather slots than laps (a brief not filled in yet) gives lap ranges, not a crash', () {
    final forecast = WeatherForecast.tryParse('R06/R05/C03/S14/S04/R03/R04/R05')!;
    for (final laps in [0, 1, 2, 5]) {
      for (final phase in forecast.phases) {
        final (from, to) = forecast.lapsOfPhase(phase, laps);
        expect(from, greaterThanOrEqualTo(1));
        expect(to, greaterThanOrEqualTo(from));
      }
      expect(() => PitStopCalculator.calculate(_brief('R06/R05/C03/S14/S04/R03/R04/R05', laps: laps < 1 ? 1 : laps)), returnsNormally);
    }
  });

  test('half a lap of fuel is kept for the finish', () {
    // 40 laps at 2.5%/lap is exactly 100% -- with half a lap kept back it
    // no longer fits one tank, so there's a stop.
    final plan = PitStopCalculator.calculate(_brief('C01', laps: 40), measuredPercentPerLap: 2.5, maxFuelMap: 1);
    expect(plan.pitStops, hasLength(1));
    expect(plan.summary, contains('1.3% fuel (half a lap) in reserve'));
    expect(
      PitStopCalculator.calculate(_brief('C01', laps: 39), measuredPercentPerLap: 2.5, maxFuelMap: 1).pitStops,
      isEmpty,
    );
  });

  // A wet test stint: [n] laps in [weather] on [tyre] at [ms] a lap.
  List<PracticeLapRecord> wetStint(int stint, String weather, String tyre, int ms, {int n = 4}) => [
    for (var i = 0; i < n; i++)
      PracticeLapRecord(
        lapNumber: i + 1,
        lapTimeMs: ms + i * 10,
        tireCompound: tyre,
        fuelPercentAtLapStart: 100 - i * 3.0,
        fuelPercentAtLapEnd: 97 - i * 3.0,
        recordedAt: DateTime(2026),
        stintNumber: stint,
        weather: weather,
      ),
  ];

  test('your wet testing picks the wet tyre: Wets quicker in R06 and R05 means starting on Wets', () {
    final laps = [
      ...wetStint(1, 'R06', 'Heavy Wet', 104000),
      ...wetStint(2, 'R06', 'Intermediate', 106000),
      ...wetStint(3, 'R05', 'Intermediate', 103500),
      ...wetStint(4, 'R05', 'Heavy Wet', 103000),
    ];
    final plan = PitStopCalculator.calculate(_brief('R06/R05/C03/S14/S04/R03/R04/R05'), wetPace: WetPaceTable.fromLaps(laps));
    expect(plan.startingTireCompound, 'Heavy Wet');
    expect(plan.basis.where((b) => b.startsWith('Laps 1-7')).single, contains('from your wet testing in R06/R05'));
    // The closing spell wasn't tested in R03/R04 -- R05 was: still measured.
    expect(plan.basis.where((b) => b.startsWith('Laps 17-26')).single, contains('from your wet testing in R05'));
  });

  test('without wet testing it says it used the community guide, and that fuel is assumed', () {
    final plan = PitStopCalculator.calculate(_brief('R06/R05/C03/S14/S04/R03/R04/R05'));
    expect(plan.basis.first, contains('assumed'));
    expect(plan.basis.where((b) => b.startsWith('Laps 1-7')).single, contains('community tyre guide'));
  });

  test('the change list says what moved, and nothing when the plan is the same', () {
    final before = PitStopCalculator.calculate(_brief('R06/R05/C03/S14/S04/R03/R04/R05'));
    final laps = [...wetStint(1, 'R06', 'Heavy Wet', 104000), ...wetStint(2, 'R06', 'Intermediate', 106000)];
    final after = PitStopCalculator.calculate(
      _brief('R06/R05/C03/S14/S04/R03/R04/R05'),
      measuredPercentPerLap: 3.1,
      wetPace: WetPaceTable.fromLaps(laps),
    ).withPractice(done: 2, planned: 7);
    final changes = StrategyChanges.between(before, after);
    expect(changes, contains('Start tyre: Inters → Wets'));
    expect(changes, contains('Fuel: 1.70 → 3.10%/lap'));
    expect(changes, contains('Stint tests done: 0 → 2 of 7'));
    expect(StrategyChanges.between(before, before), isEmpty);
  });
}
