// Plan B (the second-best strategy) and planning the rest of the race
// again mid-race (switching between Plan A and Plan B).
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/models/race_strategy.dart';
import 'package:boxbox/services/base_rates.dart';
import 'package:boxbox/services/dry_tyre_pace.dart';
import 'package:boxbox/services/pit_stop_calculator.dart';

RaceBriefing _brief({int laps = 13, int minStops = 2, String mandatory = 'N/A'}) => RaceBriefing(
  trackName: 'Circuit de Sainte-Croix - C',
  totalLaps: laps,
  startingFuelPercent: 100,
  fuelConsumptionMultiplier: 4,
  tyreWearMultiplier: 2,
  mandatoryPitStopCount: minStops,
  mandatoryTyreCompound: mandatory,
  availableTireCompounds: const ['Racing Hard', 'Racing Soft', 'Intermediate', 'Heavy Wet'],
);

List<PracticeLapRecord> _stint(int stint, String tyre, List<int> times, {int from = 1}) => [
  for (final (i, t) in times.indexed)
    PracticeLapRecord(
      lapNumber: from + i,
      lapTimeMs: t,
      tireCompound: tyre,
      fuelPercentAtLapStart: 100 - i * 19,
      fuelPercentAtLapEnd: 100 - (i + 1) * 19,
      recordedAt: DateTime(2026, 11, 19),
      stintNumber: stint,
    ),
];

BaseRates _wear(double hardPerLap, double softPerLap) => BaseRates(wear: {
  'Racing Hard': BaseRate(perXPerKm: hardPerLap / 2 / 10.76, tracks: const ['Test'], laps: 10),
  'Racing Soft': BaseRate(perXPerKm: softPerLap / 2 / 10.76, tracks: const ['Test'], laps: 10),
});

final _pace = DryTyrePace.fromLaps([
  ..._stint(1, 'Racing Hard', [224000, 224200, 224100, 224300]),
  ..._stint(2, 'Racing Soft', [219000, 219200, 218900, 219100], from: 5),
]);

RaceStrategy _plan({int minStops = 2, String mandatory = 'N/A'}) => PitStopCalculator.calculate(
  _brief(minStops: minStops, mandatory: mandatory),
  trackLengthMeters: 10760,
  measuredPercentPerLap: 19.3,
  baseRates: _wear(3.7, 7.5),
  dryPace: _pace,
  maxFuelMap: 1,
);

List<String> _stops(RaceStrategy s) => [for (final p in s.pitStops) '${p.lap} ${p.tireCompound.replaceFirst('Racing ', '')}'];

void main() {
  test('Plan B differs from Plan A in stops or tyres, and is slower', () {
    final plan = _plan();
    final b = plan.planB!;
    expect(_stops(plan), ['3 Soft', '7 Soft', '10 Soft']);
    final sameStops = b.pitStops.length == plan.pitStops.length;
    final sameTyres = b.stintTyres.toSet().containsAll(plan.stintTyres.toSet()) && plan.stintTyres.toSet().containsAll(b.stintTyres.toSet());
    expect(sameStops && sameTyres, isFalse);
    expect(b.secondsBehindPlanA, greaterThan(0));
    expect(b.summary, startsWith('Plan B: '));
    expect(plan.basis, contains(b.summary));
  });

  test('saved and loaded: Plan B and the plan inputs survive', () {
    final plan = _plan();
    final back = RaceStrategy.fromMap(plan.toMap());
    expect(_stops(back.planB!), _stops(plan.planB!));
    expect(back.inputs!.tyres.map((t) => t.compound), plan.inputs!.tyres.map((t) => t.compound));
    expect(back.inputs!.totalLaps, 13);
  });

  test('re-plan before lap 1 is the plan itself', () {
    final plan = _plan();
    final again = PitStopCalculator.replan(plan.inputs!, plan.planB!, lapsDone: 0, fuelPercent: 100, currentTyre: 'Racing Soft', lapsOnTyre: 0);
    expect(identical(again, plan.planB), isTrue);
  });

  test('switching to Plan B mid-race keeps the stops made and plans the rest from here', () {
    final plan = _plan();
    final b = plan.planB!;
    // 5 laps in, one stop made on lap 4: 1 lap on fresh Softs, 81% fuel.
    final live = PitStopCalculator.replan(plan.inputs!, b,
        lapsDone: 5, fuelPercent: 81, currentTyre: 'Racing Soft', lapsOnTyre: 1, stopLapsMade: [4])!;
    expect(live.pitStops.first.lap, 4);
    expect(live.pitStops.length, b.pitStops.length.clamp(1, 99));
    for (final p in live.pitStops.skip(1)) {
      expect(p.lap, greaterThan(5));
      expect(p.lap, lessThan(13));
    }
    expect(live.summary, startsWith('From lap 6: '));
  });

  test('re-plan: the fuel in the tank decides how soon the next stop is', () {
    final plan = _plan();
    // Lap 2 done, only 30% fuel (one lap and a bit at 19.3%/lap): box now.
    final live = PitStopCalculator.replan(plan.inputs!, plan,
        lapsDone: 2, fuelPercent: 30, currentTyre: 'Racing Soft', lapsOnTyre: 2)!;
    expect(live.pitStops.first.lap, 3);
  });

  test('re-plan: worn tyres bring the stop forward', () {
    final plan = _plan();
    // Softs at 7.5%/lap with 40% left: 1 more lap to 30%.
    final live = PitStopCalculator.replan(plan.inputs!, plan,
        lapsDone: 1, fuelPercent: 81, currentTyre: 'Racing Soft', lapsOnTyre: 1, tyreLeftPercent: 40)!;
    expect(live.pitStops.first.lap, 2);
  });

  test('re-plan owes the mandatory tyre until it has been run', () {
    final plan = _plan(mandatory: 'Racing Hard');
    final owed = PitStopCalculator.replan(plan.inputs!, plan,
        lapsDone: 5, fuelPercent: 81, currentTyre: 'Racing Soft', lapsOnTyre: 1, stopLapsMade: [4])!;
    expect(owed.pitStops.skip(1).any((p) => p.tireCompound == 'Racing Hard'), isTrue);
    final run = PitStopCalculator.replan(plan.inputs!, plan,
        lapsDone: 5, fuelPercent: 81, currentTyre: 'Racing Soft', lapsOnTyre: 1, stopLapsMade: [4], mandatoryRun: true)!;
    expect(run.pitStops.skip(1).every((p) => p.tireCompound == 'Racing Soft'), isTrue);
  });

  test('Plan A on Softs only: one alternative runs Softs and Hards, no stint a token lap', () {
    final plan = _plan();
    // Here the two-tyre plan is the quicker alternative, so it's Plan B.
    final c = plan.planB!;
    expect(c.stintTyres.toSet(), {'Racing Soft', 'Racing Hard'});
    final stops = [for (final p in c.pitStops) p.lap];
    final lengths = PitStopCalculator.stintLengths(13, stops);
    expect(lengths.every((l) => l >= 2), isTrue);
    expect(c.secondsBehindPlanA, greaterThan(0));
    expect(c.summary, startsWith('Plan B: '));
    expect(RaceStrategy.fromMap(plan.toMap()).planC!.summary, plan.planC!.summary);
    expect(plan.alternatives.map((a) => a.$1), ['B', 'C']);
    // Plan B is always the quicker of the two.
    expect(plan.planB!.secondsBehindPlanA, lessThanOrEqualTo(plan.planC!.secondsBehindPlanA!));
    expect(plan.planC!.summary, contains('1 stop more'));
  });

  test('switching to the two-tyre plan mid-race keeps both tyres in it', () {
    final plan = _plan();
    final live = PitStopCalculator.replan(plan.inputs!, plan.planB!,
        lapsDone: 2, fuelPercent: 62, currentTyre: 'Racing Soft', lapsOnTyre: 2)!;
    expect(live.pitStops.any((p) => p.tireCompound == 'Racing Hard'), isTrue);
  });

  test('only one dry tyre allowed: no Plan C', () {
    final brief = RaceBriefing(
      trackName: 'Test',
      totalLaps: 13,
      startingFuelPercent: 100,
      fuelConsumptionMultiplier: 4,
      mandatoryPitStopCount: 2,
      availableTireCompounds: const ['Racing Soft', 'Intermediate', 'Heavy Wet'],
    );
    expect(PitStopCalculator.calculate(brief, trackLengthMeters: 10760).planC, isNull);
  });

  test("Plan B's time behind Plan A, in short", () {
    RaceStrategy b(double? s) => RaceStrategy(pitStops: const [], startingTireCompound: 'Racing Soft', summary: '', assumedPercentPerLap: 1, secondsBehindPlanA: s);
    expect(b(24.4).behindPlanALabel, '+24s');
    expect(b(65).behindPlanALabel, '+1m 05s');
    expect(b(null).behindPlanALabel, isNull);
  });

  test('a wet race has no Plan B', () {
    final wet = RaceBriefing(
      trackName: 'Test',
      totalLaps: 13,
      startingFuelPercent: 100,
      fuelConsumptionMultiplier: 4,
      tyreWearMultiplier: 2,
      availableTireCompounds: const ['Racing Soft', 'Intermediate', 'Heavy Wet'],
      weatherSlots: 'R06/C03',
      wetOrChangeableWeather: true,
    );
    final plan = PitStopCalculator.calculate(wet, trackLengthMeters: 10760);
    expect(plan.planB, isNull);
    expect(plan.inputs, isNull);
  });
}
