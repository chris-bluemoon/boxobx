// Covers the Race Mode fuel target (FuelTarget) and when Boxington calls
// it out (FuelCallAdvisor).
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/race_strategy.dart';
import 'package:boxbox/services/fuel_target.dart';

const _stop = PlannedPitStop(lap: 10, tireCompound: 'Racing Medium', reasoning: '');

FuelTarget? _target({
  int lap = 5,
  double fuel = 51,
  double using = 8,
  List<PlannedPitStop> stops = const [_stop],
  int stopsMade = 0,
  int? total = 20,
  int map = 1,
}) => FuelTarget.of(
  currentLap: lap,
  fuelAtLapStart: fuel,
  usingPerLap: using,
  plannedStops: stops,
  stopsMade: stopsMade,
  totalLaps: total,
  planMap: map,
);

void main() {
  group('FuelTarget', () {
    test('works to the next planned stop: laps 5-10 on 51% is 8.33% a lap', () {
      final t = _target()!;
      expect(t.targetLap, 10);
      expect(t.toFinish, isFalse);
      expect(t.lapsLeft, 6);
      expect(t.needPerLap, closeTo(50 / 6, 0.001));
      expect(t.status, FuelTargetStatus.ok);
      expect(t.tileValue, 'OK');
    });

    test('using too much: the map steps leaner that close the gap', () {
      // Need 8.33; 9.0 on Map 1 -> Map 2 (x0.92 = 8.28) makes it.
      expect(_target(using: 9)!.leanerMaps, 1);
      // 10.0 -> Map 2 = 9.2, Map 3 = 8.4, Map 4 = 7.6: three steps.
      final t = _target(using: 10)!;
      expect(t.status, FuelTargetStatus.save);
      expect(t.leanerMaps, 3);
      expect(t.tileValue, '+3 MAP');
    });

    test('steps are relative to the plan map', () {
      // On Map 3 (x0.84), Map 4 is x0.76: 9.0 * 0.76 / 0.84 = 8.14 < 8.33.
      expect(_target(using: 9, map: 3)!.leanerMaps, 1);
    });

    test("can't make it even on the leanest map: box by the lap it runs dry", () {
      final t = _target(using: 20)!;
      expect(t.status, FuelTargetStatus.boxEarly);
      expect(t.emptyLap, 6); // 51% at 20 a lap: laps 5 and 6
      expect(t.tileValue, 'BOX L6');
    });

    test('room to spare on a lean map: how many maps richer still make it', () {
      // Plan Map 3, using 6.0: Map 2 = 6.0 * 0.92/0.84 = 6.57, Map 1 = 7.14 -- both under 8.33.
      final t = _target(using: 6, map: 3)!;
      expect(t.status, FuelTargetStatus.ok);
      expect(t.richerMaps, 2);
    });

    test('with the stop made, it works to the flag', () {
      final t = _target(lap: 12, fuel: 81, stopsMade: 1)!;
      expect(t.toFinish, isTrue);
      expect(t.targetLap, 20);
      expect(t.lapsLeft, 9);
    });

    test('no planned stops and no race length: nothing to work to', () {
      expect(_target(stops: const [], total: null), isNull);
    });

    test('no consumption measured yet: no target', () {
      expect(
        FuelTarget.of(currentLap: 1, fuelAtLapStart: 100, usingPerLap: null, plannedStops: const [], stopsMade: 0, totalLaps: 20),
        isNull,
      );
    });
  });

  group('FuelCallAdvisor', () {
    test('quiet while on target; calls when it has to save', () {
      final advisor = FuelCallAdvisor();
      expect(advisor.check(_target(fuel: 60), currentLap: 5), isNull); // 9.8 a lap to spare
      final call = advisor.check(_target(using: 10), currentLap: 5);
      expect(call, isNotNull);
      expect(call!.toCallPrompt(), contains('3 fuel maps leaner'));
      // Same advice again: nothing.
      expect(advisor.check(_target(using: 10), currentLap: 5), isNull);
    });

    test('a change waits for the average to catch up -- except box early', () {
      final advisor = FuelCallAdvisor();
      expect(advisor.check(_target(lap: 4, using: 10), currentLap: 4), isNotNull);
      expect(advisor.check(_target(lap: 5, using: 9), currentLap: 5), isNull); // too soon
      expect(advisor.check(_target(lap: 5, using: 20), currentLap: 5), isNotNull); // urgent
    });

    test('nothing on the last lap of the fuel', () {
      expect(FuelCallAdvisor().check(_target(lap: 10, fuel: 5, using: 9), currentLap: 10), isNull);
    });
  });
}
