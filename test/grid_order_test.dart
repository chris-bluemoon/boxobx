// The grid decides the tyre order: from the front row, the faster tyre
// first (hold track position); lower down, the slower one first (run long
// while the cars ahead stop, attack on fresh tyres at the end).
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/models/race_strategy.dart';
import 'package:boxbox/services/pit_stop_calculator.dart';

RaceBriefing _alsace({int? grid}) => RaceBriefing(
  trackName: 'Alsace - Village (Reverse)',
  totalLaps: 32,
  startingFuelPercent: 100,
  fuelConsumptionMultiplier: 2,
  tyreWearMultiplier: 2,
  availableTireCompounds: const ['Racing Medium', 'Racing Soft'],
  gridPosition: grid,
);

RaceStrategy _plan({int? grid}) => PitStopCalculator.calculate(_alsace(grid: grid), trackLengthMeters: 5345);

double _raceSeconds(RaceStrategy p) {
  final inputs = p.inputs!;
  final laps = PitStopCalculator.stintLengths(inputs.totalLaps, [for (final s in p.pitStops) s.lap]);
  return [for (final (i, t) in p.stintTyres.indexed) laps[i] * inputs.tyre(t)!.lapSeconds].fold(0.0, (a, b) => a + b);
}

void main() {
  test('the front row: P1 and P2; from P3 down, the slower tyre first', () {
    expect(PitStopCalculator.startsNearFront(1), isTrue);
    expect(PitStopCalculator.startsNearFront(2), isTrue);
    expect(PitStopCalculator.startsNearFront(3), isFalse);
  });

  test('starting P2: Softs first', () {
    final plan = _plan(grid: 2);
    expect(plan.startingTireCompound, 'Racing Soft');
    expect(plan.basis.any((b) => b.startsWith('Starting P2: Softs first to hold track position')), isTrue);
  });

  test('starting P9: Mediums first, the Softs at the end -- the same stops and race time', () {
    final front = _plan(grid: 2);
    final back = _plan(grid: 9);
    expect(back.startingTireCompound, 'Racing Medium');
    expect(back.pitStops.last.tireCompound, 'Racing Soft');
    expect(back.pitStops, hasLength(front.pitStops.length));
    expect(_raceSeconds(back), closeTo(_raceSeconds(front), 1e-6));
    expect(back.basis.any((b) => b.startsWith('Starting P9: Mediums first') && b.contains('worn tyres')), isTrue);
    expect(back.summary, contains('starting on Racing Medium'));
  });

  test('starting P3: already the Mediums first', () {
    expect(_plan(grid: 3).startingTireCompound, 'Racing Medium');
    expect(_plan(grid: 3).basis.any((b) => b.startsWith('Starting P3: Mediums first')), isTrue);
  });

  test('grid not entered: the plan as before, with both cases spelt out', () {
    final plan = _plan();
    expect(plan.startingTireCompound, 'Racing Soft');
    final note = plan.basis.singleWhere((b) => b.startsWith('Grid not entered'));
    expect(note, contains('front row (P1-P2)'));
    expect(note, contains('from P3 down, the Mediums first'));
  });

  test('one tyre all race: no grid line', () {
    final brief = RaceBriefing(
      trackName: 'Test',
      totalLaps: 20,
      startingFuelPercent: 100,
      availableTireCompounds: const ['Racing Hard'],
      gridPosition: 12,
    );
    expect(PitStopCalculator.calculate(brief).basis.any((b) => b.contains('Starting P') || b.contains('Grid')), isFalse);
  });

  test('Plan B and C follow the grid too', () {
    for (final (_, alt) in _plan(grid: 12).alternatives) {
      final tyres = alt.stintTyres.toSet();
      if (tyres.length > 1) expect(alt.startingTireCompound, isNot('Racing Soft'));
    }
  });

  test('swapping a saved plan mid-way: the stops and summary follow, kept through saving', () {
    final front = _plan(grid: 2);
    expect(PitStopCalculator.tyreOrderDiffers(front, slowFirst: true), isTrue);
    expect(PitStopCalculator.tyreOrderDiffers(front, slowFirst: false), isFalse);
    final swapped = PitStopCalculator.withTyreOrder(RaceStrategy.fromMap(front.toMap()), slowFirst: true);
    expect(swapped.startingTireCompound, 'Racing Medium');
    expect(swapped.pitStops.last.tireCompound, 'Racing Soft');
    expect(_raceSeconds(swapped), closeTo(_raceSeconds(front), 1e-6));
    expect(swapped.summary, contains('the slower tyre first'));
    expect(swapped.planB?.summary, front.planB?.summary);
  });

  test('the home page caveat: the other order, where it applies and its stops', () {
    final plan = _plan();
    final swapped = PitStopCalculator.withTyreOrder(plan, slowFirst: true);
    final caveat = PitStopCalculator.gridCaveat(plan)!;
    expect(caveat, startsWith('Grid: this order from P1-P2. From P3 down, start on Medium and box lap ${swapped.pitStops.first.lap}'));
    expect(caveat, contains('Enter your grid after qualifying'));
    expect(PitStopCalculator.gridCaveat(_plan(grid: 9)), startsWith('Starting P9: Mediums first'));
    expect(PitStopCalculator.gridCaveat(_plan(grid: 2)), 'Starting P2: Softs first to hold track position');
  });
}
