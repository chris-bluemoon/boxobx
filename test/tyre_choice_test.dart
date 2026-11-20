// Which tyre each stint goes on: the fastest one that lasts it, from
// practice pace and wear.
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/services/base_rates.dart';
import 'package:boxbox/services/dry_tyre_pace.dart';
import 'package:boxbox/services/pit_stop_calculator.dart';

RaceBriefing _brief({int laps = 13, String mandatory = 'N/A', List<String>? tyres}) => RaceBriefing(
  trackName: 'Circuit de Sainte-Croix - C',
  totalLaps: laps,
  startingFuelPercent: 100,
  fuelConsumptionMultiplier: 4,
  tyreWearMultiplier: 2,
  mandatoryPitStopCount: 2,
  mandatoryTyreCompound: mandatory,
  availableTireCompounds: tyres ?? const ['Racing Hard', 'Racing Soft', 'Intermediate', 'Heavy Wet'],
);

/// A full-tank stint of [times] (ms) on [tyre].
List<PracticeLapRecord> _stint(int stint, String tyre, List<int> times, {int from = 1, double startFuel = 100, int? fuelMap, List<double>? wear}) => [
  for (final (i, t) in times.indexed)
    PracticeLapRecord(
      lapNumber: from + i,
      lapTimeMs: t,
      tireCompound: tyre,
      fuelPercentAtLapStart: startFuel - i * 19,
      fuelPercentAtLapEnd: startFuel - (i + 1) * 19,
      recordedAt: DateTime(2026, 11, 19),
      stintNumber: stint,
      fuelMap: fuelMap,
      tireWearPercent: wear?[i],
    ),
];

BaseRates _wear(double hardPerLap, double softPerLap) => BaseRates(wear: {
  'Racing Hard': BaseRate(perXPerKm: hardPerLap / 2 / 10.76, tracks: const ['Test'], laps: 10),
  'Racing Soft': BaseRate(perXPerKm: softPerLap / 2 / 10.76, tracks: const ['Test'], laps: 10),
});

void main() {
  test('Round 6: Softs all race -- faster and they last the 5-lap stints', () {
    final pace = DryTyrePace.fromLaps([
      ..._stint(1, 'Racing Hard', [221392, 221839, 220140, 219462]),
      ..._stint(2, 'Racing Soft', [219900, 219300, 218800, 219100], from: 5),
    ]);
    expect(pace['Racing Soft']!.lapMs, lessThan(pace['Racing Hard']!.lapMs));
    final plan = PitStopCalculator.calculate(_brief(), trackLengthMeters: 10760, measuredPercentPerLap: 19.3,
        baseRates: _wear(3, 6), dryPace: pace, maxFuelMap: 1);
    expect(plan.startingTireCompound, 'Racing Soft');
    expect([for (final s in plan.pitStops) s.tireCompound], ['Racing Soft', 'Racing Soft', 'Racing Soft']);
    expect(plan.basis, contains(startsWith('Softs all race: 1.6s a lap faster than Hards in your practice laps; they last about 11 laps')));
  });

  test('no practice pace or wear: Softs, and the plan says the stint test checks they last', () {
    final plan = PitStopCalculator.calculate(_brief(), trackLengthMeters: 10760, maxFuelMap: 1);
    expect(plan.startingTireCompound, 'Racing Soft');
    expect(plan.basis.any((b) => b.startsWith('Softs all race: the fastest tyre allowed') && b.contains('Soft stint test checks')), isTrue);
  });

  test("Softs that don't last a stint give way to Hards for it", () {
    // 13 laps, 1 stop at x1: stints of 6 and 7. Softs at 12%/lap last 5.
    final brief = RaceBriefing(
      trackName: 'Test',
      totalLaps: 13,
      startingFuelPercent: 100,
      fuelConsumptionMultiplier: 4,
      tyreWearMultiplier: 2,
      mandatoryPitStopCount: 1,
      availableTireCompounds: const ['Racing Hard', 'Racing Soft'],
    );
    final plan = PitStopCalculator.calculate(brief, trackLengthMeters: 10760, measuredPercentPerLap: 7, baseRates: _wear(3, 12), maxFuelMap: 1);
    // 5 laps on Softs (all they last) and 8 on Hards -- either way round
    // is as quick, so the stop nearer half distance: Hards, then Softs.
    expect(plan.startingTireCompound, 'Racing Hard');
    expect([for (final s in plan.pitStops) '${s.lap} ${s.tireCompound}'], ['8 Racing Soft']);
    expect(plan.basis, contains(startsWith('Hards for stint 1: Softs last only 5 laps')));
  });

  test('a Soft that went off in practice counts that as its life', () {
    final pace = DryTyrePace.fromLaps([
      ..._stint(1, 'Racing Soft', [90000, 90100, 89900, 90000, 92000, 92500, 93000, 93400]),
    ]);
    expect(pace['Racing Soft']!.dropOffAfterLaps, 4);
    final brief = RaceBriefing(
      trackName: 'Test',
      totalLaps: 12,
      startingFuelPercent: 100,
      fuelConsumptionMultiplier: 1,
      mandatoryPitStopCount: 1,
      availableTireCompounds: const ['Racing Hard', 'Racing Soft'],
    );
    final plan = PitStopCalculator.calculate(brief, measuredPercentPerLap: 2, dryPace: pace, maxFuelMap: 1);
    // Softs held on for 4: 4 laps on them, then Hards for 8.
    expect(plan.startingTireCompound, 'Racing Soft');
    expect([for (final s in plan.pitStops) '${s.lap} ${s.tireCompound}'], ['4 Racing Hard']);
  });

  test('a stop on lap N ends that stint: 13 laps, stops on 4 and 9, are stints of 4, 5 and 4', () {
    expect(PitStopCalculator.stintLengths(13, [4, 9]), [4, 5, 4]);
    expect(PitStopCalculator.stintLengths(13, []), [13]);
  });

  test('a mandatory compound the plan would skip: as few laps as can be, at the end', () {
    final plan = PitStopCalculator.calculate(_brief(mandatory: 'Racing Hard'), trackLengthMeters: 10760,
        measuredPercentPerLap: 19.3, baseRates: _wear(3, 6), maxFuelMap: 1);
    expect([plan.startingTireCompound, for (final s in plan.pitStops) s.tireCompound],
        ['Racing Soft', 'Racing Soft', 'Racing Soft', 'Racing Hard']);
    expect([for (final s in plan.pitStops) s.lap], [4, 8, 12], reason: 'one lap on Hards to finish');
    expect(plan.basis, contains('Hards on stint 4: the brief makes them mandatory.'));
  });

  test("a tyre is timed from its longest stint: a later 2-lap run doesn't replace a full tank", () {
    final pace = DryTyrePace.fromLaps([
      ..._stint(1, 'Racing Hard', [221392, 221839, 220140, 219462]),
      ..._stint(5, 'Racing Hard', [227578, 224772], from: 13),
    ]);
    expect(pace['Racing Hard']!.laps, 4);
    expect(pace['Racing Hard']!.lapMs, (221392 + 220140) / 2);
  });

  test('fuel map, low-fuel and wet runs are not timed for dry pace', () {
    final pace = DryTyrePace.fromLaps([
      ..._stint(1, 'Racing Hard', [221000, 221000, 221000]),
      ..._stint(2, 'Racing Soft', [210000, 210000, 210000], from: 4, startFuel: 40),
      ..._stint(3, 'Racing Hard', [215000, 215000, 215000], from: 7, fuelMap: 2),
    ]);
    expect(pace.keys, ['Racing Hard']);
    expect(pace['Racing Hard']!.lapMs, 221000);
  });

  group('drop-off on a short, heavy-fuel tank', () {
    // 4 laps, 19% fuel a lap: the car gains about 0.7-0.9s a lap as it lightens.
    test('Round 6 Softs: quicker every lap only because of the fuel -- held their pace, 33% worn', () {
      final laps = _stint(2, 'Racing Soft', [217187, 215974, 215329, 214556], wear: [89.2, 81.1, 75.0, 66.7]);
      final pace = DryTyrePace.fromLaps(laps);
      expect(pace['Racing Soft']!.dropOffAfterLaps, isNull);
      expect(pace['Racing Soft']!.heldPaceLaps, 4);
      final plan = PitStopCalculator.calculate(_brief(), trackLengthMeters: 10760, measuredPercentPerLap: 19.3,
          baseRates: _wear(3, 7.5), dryPace: pace, maxFuelMap: 1);
      expect(plan.basis, contains('Softs: held their pace for all 4 laps of a stint in practice here (33% worn) -- any further is projected from the wear.'));
    });

    test('lap times that stay flat as the fuel burns are the tyres going off', () {
      // Without the fuel allowance these look steady; with it, laps 3-4 are
      // about 1.5-2.5s down on the first two.
      final stint = _stint(1, 'Racing Soft', [216000, 216100, 216300, 216400]);
      final hard = _stint(2, 'Racing Hard', [221400, 220700, 220000, 219300], from: 5); // fuel's worth, measured
      final pace = DryTyrePace.fromLaps([...stint, ...hard]);
      expect(pace['Racing Soft']!.dropOffAfterLaps, 2);
      expect(pace['Racing Hard']!.dropOffAfterLaps, isNull);
    });
  });

  group('an extra stop to run a faster tyre', () {
    // 20 laps, a tank lasts 19: one stop on fuel. Softs last 9 laps, Hards 18.
    RaceBriefing brief() => RaceBriefing(
      trackName: 'T',
      totalLaps: 20,
      startingFuelPercent: 100,
      fuelConsumptionMultiplier: 1,
      tyreWearMultiplier: 1,
      availableTireCompounds: const ['Racing Hard', 'Racing Soft'],
    );
    final rates = BaseRates(wear: {
      'Racing Hard': BaseRate(perXPerKm: 3.8 / 5, tracks: const ['T'], laps: 9),
      'Racing Soft': BaseRate(perXPerKm: 7.5 / 5, tracks: const ['T'], laps: 9),
    });
    Map<String, DryTyrePace> pace(int hardMs) => {
      'Racing Hard': DryTyrePace('Racing Hard', hardMs.toDouble(), 5),
      'Racing Soft': const DryTyrePace('Racing Soft', 90000, 5),
    };
    // One stop: at best 9 laps on Softs, then 11 on Hards.
    test('Softs 5s a lap faster: 2 stops on Softs beat Softs then Hards on 1', () {
      final plan = PitStopCalculator.calculate(brief(), trackLengthMeters: 5000, measuredPercentPerLap: 5,
          measuredPitStopTimeLossSeconds: 19, baseRates: rates, dryPace: pace(95000), maxFuelMap: 1);
      expect([plan.startingTireCompound, for (final s in plan.pitStops) s.tireCompound], ['Racing Soft', 'Racing Soft', 'Racing Soft']);
      // 11 laps on Hards cost 55s; the extra stop 19s.
      expect(plan.basis, contains(startsWith('An extra stop for Softs all race: about 36s quicker than Softs then Hards on 1 stop')));
      expect(plan.totalEstimatedTimeLossSeconds, 38);
    });

    test('Softs only 1s a lap faster: the extra stop does not pay -- 1 stop, Softs then Hards', () {
      final plan = PitStopCalculator.calculate(brief(), trackLengthMeters: 5000, measuredPercentPerLap: 5,
          measuredPitStopTimeLossSeconds: 19, baseRates: rates, dryPace: pace(91000), maxFuelMap: 1);
      expect([plan.startingTireCompound, for (final s in plan.pitStops) s.tireCompound], ['Racing Soft', 'Racing Hard']);
      expect(plan.pitStops.single.lap, 9, reason: 'as long on Softs as they last');
      expect(plan.basis.any((b) => b.contains('extra stop')), isFalse);
    });

    test('without both tyres timed here, the fewest stops', () {
      final plan = PitStopCalculator.calculate(brief(), trackLengthMeters: 5000, measuredPercentPerLap: 5,
          measuredPitStopTimeLossSeconds: 19, baseRates: rates, dryPace: {'Racing Soft': const DryTyrePace('Racing Soft', 90000, 5)}, maxFuelMap: 1);
      expect(plan.pitStops, hasLength(1));
    });
  });
}
