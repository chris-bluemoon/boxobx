// Fuel use and tyre wear carried over from earlier rounds: scaled to 1x
// and a 1 km lap, then back to the next round's settings.
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/models/race_strategy.dart';
import 'package:boxbox/services/base_rates.dart';
import 'package:boxbox/services/pit_stop_calculator.dart';

PracticeLapRecord _lap(int n, {double fuelUsed = 4.4, double? wear, String tyre = 'Racing Hard', int stint = 1, bool pit = false, double startFuel = 90}) =>
    PracticeLapRecord(
      lapNumber: n,
      lapTimeMs: 92000,
      tireCompound: tyre,
      fuelPercentAtLapStart: startFuel,
      fuelPercentAtLapEnd: startFuel - fuelUsed,
      tireWearPercent: wear,
      recordedAt: DateTime(2026, 11, 16),
      stintNumber: stint,
      isPitLap: pit,
    );

// Round 5: Nurburgring Sprint, 3,335 m, fuel x3, tyre wear x6.
RoundLaps _nurburgring(List<PracticeLapRecord> laps) =>
    RoundLaps(track: 'Nürburgring Sprint', trackLengthMeters: 3335, fuelMultiplier: 3, tyreWearMultiplier: 6, laps: laps);

RaceBriefing _sainteCroix() => RaceBriefing(
  trackName: 'Circuit de Sainte-Croix - C',
  totalLaps: 13,
  startingFuelPercent: 100,
  fuelConsumptionMultiplier: 4,
  tyreWearMultiplier: 2,
  availableTireCompounds: const ['Racing Hard', 'Racing Medium', 'Racing Soft'],
);

void main() {
  test('fuel: 4.4%/lap at x3 on 3.3 km is 19%/lap at x4 on 10.8 km; pit laps and fuel-off laps left out', () {
    final rates = BaseRates.fromRounds([
      _nurburgring([
        for (var n = 1; n <= 10; n++) _lap(n),
        _lap(11, fuelUsed: -30, pit: true), // the refuel
        _lap(12, fuelUsed: 0, startFuel: 100), // qualifying, fuel off
      ]),
    ]);
    expect(rates.fuel!.laps, 10);
    expect(rates.fuel!.perLap(4, 10760), closeTo(4.4 / 3 / 3.335 * 4 * 10.76, 0.01));
  });

  test('a 13-lap Sainte-Croix C at x4 on Map 1: 3 stops from your Nurburgring fuel (the guess says 2)', () {
    final brief = _sainteCroix();
    // 1.7% at x1 on 5 km: 14.6%/lap here.
    final guess = PitStopCalculator.calculate(brief, trackLengthMeters: 10760, maxFuelMap: 1);
    expect(guess.assumedPercentPerLap, closeTo(1.7 * 4 * 10.76 / 5, 0.01));
    expect(guess.pitStops, hasLength(2));
    final rates = BaseRates.fromRounds([_nurburgring([for (var n = 1; n <= 10; n++) _lap(n)])]);
    final plan = PitStopCalculator.calculate(brief, trackLengthMeters: 10760, baseRates: rates, maxFuelMap: 1);
    expect(plan.pitStops, hasLength(3));
    expect(plan.basis.first, contains('from your laps in earlier rounds (Nürburgring Sprint) scaled to x4 and 10.8 km'));
  });

  test('a leaner fuel map that saves stops is picked, and says what it costs', () {
    final rates = BaseRates.fromRounds([_nurburgring([for (var n = 1; n <= 10; n++) _lap(n)])]);
    final plan = PitStopCalculator.calculate(_sainteCroix(), trackLengthMeters: 10760, baseRates: rates);
    expect(plan.fuelMap, greaterThan(1));
    expect(plan.pitStops.length, lessThan(3));
    expect(plan.summary, startsWith('Run Fuel Map ${plan.fuelMap}.'));
    expect(plan.basis[1], startsWith('Fuel Map ${plan.fuelMap}: about'));
    expect(plan.basis[1], contains('fewer than Map 1'));
    expect(RaceStrategy.fromMap(plan.toMap()).fuelMap, plan.fuelMap, reason: 'kept through saving');
  });

  test('when the fuel lasts anyway, Map 1 (full power) it is', () {
    final brief = RaceBriefing(
      trackName: 'Test',
      totalLaps: 10,
      startingFuelPercent: 100,
      fuelConsumptionMultiplier: 1,
      availableTireCompounds: const ['Racing Hard'],
    );
    expect(PitStopCalculator.calculate(brief).fuelMap, 1);
  });

  test('tyre wear per compound from the gauge, a misread left out', () {
    final rates = BaseRates.fromRounds([
      _nurburgring([
        _lap(1, wear: 100, pit: true),
        for (var n = 2; n <= 12; n++) _lap(n, wear: n == 7 ? 0 : 100 - (n - 2) * 3),
        for (var n = 13; n <= 18; n++) _lap(n, wear: 100 - (n - 13) * 8, tyre: 'Intermediate', stint: 2),
      ]),
    ]);
    // Hards: 3% a lap at x6 on 3.3 km.
    expect(rates.wear['Racing Hard']!.perLap(6, 3335), closeTo(3, 0.01));
    expect(rates.wear['Intermediate']!.perLap(6, 3335), closeTo(8, 0.01));
    expect(rates.wear['Racing Soft'], isNull, reason: 'never driven');
  });

  test('a tyre that wears out before the fuel runs out shortens the stints, and the plan says why', () {
    // 12% wear a lap at x2 on 10.8 km: 5 laps to 30% left.
    final brief = RaceBriefing(
      trackName: 'Circuit de Sainte-Croix - C',
      totalLaps: 13,
      startingFuelPercent: 100,
      fuelConsumptionMultiplier: 1,
      tyreWearMultiplier: 2,
      availableTireCompounds: const ['Racing Soft'],
    );
    final rates = BaseRates(wear: {'Racing Soft': BaseRate(perXPerKm: 12 / 2 / 10.76, tracks: const ['Test'], laps: 10)});
    final withoutWear = PitStopCalculator.calculate(brief, trackLengthMeters: 10760);
    final plan = PitStopCalculator.calculate(brief, trackLengthMeters: 10760, baseRates: rates);
    expect(withoutWear.pitStops, isEmpty, reason: "a tank lasts the race at x1");
    expect(plan.pitStops, hasLength(2));
    expect(plan.summary, contains('capped by tyre wear (5 laps)'));
    expect(plan.basis.any((b) => b.startsWith('Softs: about 12.0% wear a lap, so 5 laps')), isTrue);
  });
}

