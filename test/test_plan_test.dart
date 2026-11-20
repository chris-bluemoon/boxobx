import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/models/race_strategy.dart';
import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/models/test_plan.dart';
import 'package:boxbox/screens/practice_log_screen.dart';
import 'package:boxbox/services/practice_lap_logger.dart';
import 'package:boxbox/services/stint_summary.dart';
import 'package:boxbox/services/test_plan_tracker.dart';

RaceBriefing _briefing(List<String> compounds) =>
    RaceBriefing(trackName: 'Test', totalLaps: 26, startingFuelPercent: 100, availableTireCompounds: compounds);

/// A stint of [count] laps tagged to [test]: starts at [fuelStart],
/// 3%/lap, wear falling from [wearStart] by 3/lap, lap times rising by
/// [slowingMs].
List<PracticeLapRecord> _stint(
  int number, {
  int? test,
  String tyre = 'Racing Medium',
  double fuelStart = 100,
  int count = 5,
  double? wearStart = 97,
  int slowingMs = 10,
}) => [
  for (var i = 0; i < count; i++)
    PracticeLapRecord(
      lapNumber: i + 1,
      lapTimeMs: 90000 + i * slowingMs,
      tireCompound: tyre,
      fuelPercentAtLapStart: fuelStart - i * 3,
      fuelPercentAtLapEnd: fuelStart - (i + 1) * 3,
      tireWearPercent: wearStart == null ? null : wearStart - i * 3,
      recordedAt: DateTime(2026),
      stintNumber: number,
      testNumber: test,
    ),
];

TelemetryFrame _frame(int lap, double fuel) => TelemetryFrame(
  rpm: 0,
  speedKmh: 200,
  gear: 4,
  posX: 0,
  posY: 0,
  posZ: 0,
  lapDistance: 0,
  trackLength: 0,
  fuelPercent: fuel,
  tireTemps: const [0, 0, 0, 0],
  currentLap: lap,
  lastLapTimeMs: lap == 1 ? -1 : 90000,
);

void main() {
  group('building the plan', () {
    test('one full-tank stint per dry compound, hardest first, then a low-fuel run on the softest', () {
      final plan = TestPlan.fromBriefing(_briefing(['Racing Hard', 'Racing Medium', 'Racing Soft']));
      expect(plan.stints.map((s) => s.target), [
        'Hard · 100% fuel · Map 1 · until 90% worn or fuel < 5%',
        'Soft · 100% fuel · Map 1 · until 90% worn or fuel < 5%',
        'Medium · 100% fuel · Map 1 · until 90% worn or fuel < 5%',
        'Soft · 20% fuel · Map 1 · 4 laps',
        // No stop needed at x1, and assumed Softs don't last 26 laps: Mediums.
        'Full race · 26 laps · start on Medium · 100% fuel · Map 1 · change tyres when the track calls for it',
      ]);
    });

    test('a heavy fuel round: each long stint is one tank, the low-fuel run sized to it', () {
      // 18% a lap: a tank is 5 laps (half a lap kept back).
      final plan = TestPlan.fromBriefing(_briefing(['Racing Hard', 'Racing Soft']), fuelPerLapPercent: 18);
      expect(plan.stints.map((s) => s.target).take(3), [
        'Hard · 100% fuel · Map 1 · 5 laps (or until 90% worn or fuel < 5%)',
        'Soft · 100% fuel · Map 1 · 5 laps (or until 90% worn or fuel < 5%)',
        'Soft · 55% fuel · Map 1 · 2 laps',
      ]);
      // A wear rate that won't last the tank: then the tyres are the limit.
      expect(plan.stints.first.targetWith(17), 'Hard · 100% fuel · Map 1 · 5 laps (or until 90% worn or fuel < 5%)');
      expect(plan.stints.first.targetWith(4), 'Hard · 100% fuel · Map 1 · until 90% worn or fuel < 5%, about 4 laps');
      // The laps tile: the tank, unless the tyres go first (~).
      final p = TestPlanTracker.progress(plan, const []);
      expect(p.lapsFor(plan.stints.first), (5, false));
      expect(p.lapsFor(plan.stints[2]), (2, false), reason: 'the low-fuel run');
      final long = plan.stints.first;
      final stint = StintSummary.fromLaps(_stint(1, test: 1, tyre: 'Racing Hard', count: 4)).first;
      expect(TestPlanTracker.stopReason(long, stint, liveWearRemaining: 80, liveFuelPercent: 20), isNull);
      final tank = StintSummary.fromLaps(_stint(1, test: 1, tyre: 'Racing Hard', count: 5)).first;
      expect(TestPlanTracker.stopReason(long, tank, liveWearRemaining: 80, liveFuelPercent: 20), 'a full tank done (5 laps)');
    });

    test('every test names its fuel map: Map 1, the race test the strategy\'s', () {
      // The strategy's 12% a lap on Map 4 is 15.8% on Map 1: 5 laps a tank.
      final plan = TestPlan.fromBriefing(_briefing(['Racing Medium', 'Racing Soft']), fuelPerLapPercent: 12, fuelMap: 4);
      expect(plan.stints.where((s) => s.kind != TestStintKind.race).map((s) => s.fuelMap).toSet(), {1});
      expect(plan.stints.last.fuelMap, 4);
      expect(plan.stints.first.target, 'Medium · 100% fuel · Map 1 · 5 laps (or until 90% worn or fuel < 5%)');
      // A done test shows the map its laps were run on.
      final done = TestPlanTracker.progress(plan, [
        for (final l in _stint(1, test: 1, count: 25)) PracticeLapRecord.fromMap({...l.toMap(), 'fuelMap': 2}),
      ]);
      expect(done.targetFor(plan.stints.first), contains('Map 2'));
      final logger = PracticeLapLogger()..startNewStint(testNumber: 1, testCompound: 'Racing Medium', testFuelMap: 4);
      logger.update(_frame(1, 100));
      logger.update(_frame(2, 88));
      logger.startNewStint(); // NEW STINT: not a test, so Map 1
      logger.update(_frame(3, 76));
      expect(logger.laps.map((l) => l.fuelMap), [4, null]);
      // Map 4 uses 76% of Map 1's fuel (24% saved): 12% is 15.8%.
      expect(logger.laps.first.map1FuelConsumedPercent, closeTo(12 / 0.76, 0.01));
    });

    test('a light fuel round: a long stint goes no further than the race distance', () {
      final plan = TestPlan.fromBriefing(_briefing(['Racing Medium']), fuelPerLapPercent: 2); // a tank: 49 laps
      expect(plan.stints.first.target, 'Medium · 100% fuel · Map 1 · 26 laps (or until 90% worn or fuel < 5%)');
      expect(plan.stints[1].target, 'Medium · 20% fuel · Map 1 · 4 laps');
    });

    test("hardest tyre first whatever the strategy starts on -- the race test starts on the strategy's", () {
      final plan = TestPlan.fromBriefing(_briefing(['Racing Medium', 'Racing Soft']), startCompound: 'Racing Soft');
      expect(plan.stints.first.compound, 'Racing Medium');
      expect(plan.stints, hasLength(4));
      expect(plan.stints.last.compound, 'Racing Soft', reason: 'the race test starts on it too');
    });

    test('no compounds, no plan', () {
      expect(TestPlan.fromBriefing(_briefing(const [])).stints, isEmpty);
    });
  });

  group('the driver says which test a stint is for', () {
    test('starting a test tags the new stint; NEW STINT or a pit stop ends it', () {
      final logger = PracticeLapLogger();
      logger.update(_frame(1, 100));
      logger.update(_frame(2, 97));
      expect(logger.laps.last.testNumber, isNull);

      logger.startNewStint(testNumber: 2);
      expect(logger.activeTestNumber, 2, reason: 'known straight away, before a lap completes');
      logger.update(_frame(3, 94));
      logger.update(_frame(4, 91));
      expect(logger.laps.skip(1).map((l) => (l.stintNumber, l.testNumber)), [(2, 2), (2, 2)]);

      logger.startNewStint(); // NEW STINT, or a pit stop / going out again
      expect(logger.activeTestNumber, isNull);
      logger.update(_frame(5, 88));
      expect(logger.laps.last.testNumber, isNull);
    });

    test('a pit stop or going out after tapping "start test" does not cancel the test', () {
      final logger = PracticeLapLogger();
      logger.update(_frame(1, 100));
      logger.update(_frame(2, 97));

      logger.startNewStint(testNumber: 2); // tap, then drive into the pits
      logger.startNewStint(automatic: true); // pit stop detected
      logger.startNewSession(); // or back out on track
      expect(logger.activeTestNumber, 2);
      logger.update(_frame(1, 100));
      logger.update(_frame(2, 97));
      expect(logger.laps.last.testNumber, 2);

      // Pitting at the END of the test does end it.
      logger.startNewStint(automatic: true);
      expect(logger.activeTestNumber, isNull);
    });

    test('NEW STINT (driver) does cancel a test that has not started yet', () {
      final logger = PracticeLapLogger();
      logger.startNewStint(testNumber: 2);
      logger.startNewStint();
      expect(logger.activeTestNumber, isNull);
    });

    test('completing the test marks its last lap and ends it, so it counts even if the lap in progress is abandoned', () {
      final logger = PracticeLapLogger();
      logger.update(_frame(1, 100));
      logger.startNewStint(testNumber: 1);
      logger.update(_frame(2, 97));
      logger.update(_frame(3, 94));
      expect(logger.completeActiveTest(), isTrue);
      expect(logger.laps.last.testTargetReached, isTrue);
      expect(logger.laps.where((l) => l.testTargetReached), hasLength(1));
      expect(logger.activeTestNumber, isNull, reason: 'the test is closed off');
      logger.update(_frame(4, 91));
      expect(logger.laps.last.testNumber, isNull, reason: 'later laps are a normal stint');

      // Counts as done even though its saved wear never reached the target.
      final plan = TestPlan.fromBriefing(_briefing(['Racing Medium']));
      expect(TestPlanTracker.progress(plan, logger.laps).statuses.first, TestStatus.done);
      expect(PracticeLapRecord.fromMap(logger.laps[1].toMap()).testTargetReached, isTrue);
      expect(logger.completeActiveTest(), isFalse, reason: 'no test running now');
    });

    test('the stint label names the test', () {
      final s = StintSummary.fromLaps(_stint(3, test: 2, tyre: 'Racing Soft')).single;
      expect(s.label('Round 5'), 'Round 5 Practice - Stint 3 (Stint Test 2) - Fuel 100%, Tyre RS');
    });
  });

  group('progress', () {
    final plan = TestPlan.fromBriefing(_briefing(['Racing Medium', 'Racing Soft']));

    test('a tagged stint that reached 10% tyres left (90% worn) is done', () {
      final p = TestPlanTracker.progress(plan, _stint(1, test: 1, count: 30));
      expect(p.statuses, [TestStatus.done, TestStatus.toDo, TestStatus.toDo, TestStatus.toDo]);
      expect(p.next!.compound, 'Racing Soft');
    });

    test('the user is trusted on fuel, but laps on another tyre than the test\'s don\'t count', () {
      final halfFuel = _stint(1, test: 1, tyre: 'Racing Medium', fuelStart: 50, count: 25);
      expect(TestPlanTracker.progress(plan, halfFuel).statuses.first, TestStatus.done);
      final onHards = _stint(1, test: 1, tyre: 'Racing Hard', count: 25);
      expect(TestPlanTracker.progress(plan, onHards).statuses.first, TestStatus.toDo);
    });

    test('on the wrong tyre: one call, and a stop to fit the right one carries the test on', () {
      final caller = TestPlanCaller();
      final wrong = _stint(1, test: 1, tyre: 'Racing Hard', count: 2);
      final call = caller.check(plan, wrong, activeTestNumber: 1, currentStintNumber: 1, liveWearRemaining: 8);
      expect(call!.completesTest, isFalse, reason: 'worn tyres on the wrong compound do not complete it');
      expect(call.prompt, contains("don't count"));
      expect(caller.check(plan, wrong, activeTestNumber: 1, currentStintNumber: 1, liveWearRemaining: 8), isNull);

      final logger = PracticeLapLogger()
        ..startNewStint(testNumber: 1, testCompound: 'Racing Medium')
        ..currentTireCompound = 'Racing Medium';
      logger.update(_frame(1, 100));
      logger.currentTireCompound = 'Racing Hard'; // the HUD reads Hards
      expect(logger.onWrongTyreForTest, isTrue);
      logger.update(_frame(2, 97));
      logger.update(_frame(3, 94));
      logger.startNewStint(automatic: true, pitStop: true); // box, fit Mediums
      expect(logger.activeTestNumber, 1, reason: 'the test carries on');
      logger.currentTireCompound = 'Racing Medium';
      expect(logger.onWrongTyreForTest, isFalse);
      logger.update(_frame(4, 100));
      logger.update(_frame(5, 97));
      logger.startNewStint(automatic: true, pitStop: true); // on the right tyre, a stop ends it
      expect(logger.activeTestNumber, isNull);
    });

    test('untagged stints never count, even if they match the plan exactly', () {
      expect(TestPlanTracker.progress(plan, _stint(1, count: 25)).statuses.first, TestStatus.toDo);
    });

    test('the active test is in progress, even before its first lap', () {
      expect(TestPlanTracker.progress(plan, const [], activeTestNumber: 2).statuses, [
        TestStatus.toDo,
        TestStatus.inProgress,
        TestStatus.toDo,
        TestStatus.toDo,
      ]);
    });

    test('an attempt that stopped short stays to do; a later full one completes it', () {
      final short = _stint(1, test: 1, count: 4);
      expect(TestPlanTracker.progress(plan, short).statuses.first, TestStatus.toDo);
      final full = [...short, ..._stint(2, test: 1, count: 25)];
      final p = TestPlanTracker.progress(plan, full);
      expect(p.statuses.first, TestStatus.done);
      expect(p.matchedStints.first!.stintNumber, 2);
    });

    test('long stints also end on low fuel or big drop-off, without wear readings', () {
      final dropOff = _stint(1, test: 1, count: 5, wearStart: null, slowingMs: 400); // last lap 1.6s off best
      expect(TestPlanTracker.progress(plan, dropOff).statuses.first, TestStatus.done);
      final fuelOut = _stint(1, test: 1, count: 32, wearStart: null, slowingMs: 0); // ends at 4% fuel
      expect(TestPlanTracker.progress(plan, fuelOut).statuses.first, TestStatus.done);
    });

    test('the low-fuel test is done after its 4 laps, completing the plan', () {
      final laps = [
        ..._stint(1, test: 1, count: 25),
        ..._stint(2, test: 2, tyre: 'Racing Soft', count: 25),
        ..._stint(3, test: 3, tyre: 'Racing Soft', fuelStart: 20, count: 4),
      ];
      final p = TestPlanTracker.progress(plan, laps);
      expect(p.statuses[2], TestStatus.done);
      expect(p.complete, isFalse, reason: 'the full race test is still to run');
    });
  });

  group('expected laps', () {
    final plan = TestPlan.fromBriefing(_briefing(['Racing Medium', 'Racing Soft']));

    test('unknown until the compound has a measured wear rate', () {
      final p = TestPlanTracker.progress(plan, const []);
      expect(p.expectedLaps, [null, null, null, null]);
      expect(p.targetFor(plan.stints.first), 'Medium · 100% fuel · Map 1 · until 90% worn or fuel < 5%');
    });

    test('from the latest stint on that compound: 90 points of wear at its rate', () {
      // Medium wears 3%/lap -> 90 / 3 = 30 laps; any stint counts, test or not.
      final p = TestPlanTracker.progress(plan, _stint(1, count: 6));
      expect(p.expectedLaps.first, 30);
      expect(p.targetFor(plan.stints.first), 'Medium · 100% fuel · Map 1 · until 90% worn or fuel < 5% (about 30 laps)');
      expect(p.expectedLaps[1], isNull, reason: 'no Soft data yet');
      expect(p.expectedLaps.last, isNull, reason: 'low-fuel stints are a fixed lap count');
    });

    test('Boxington names the next test with its estimate when known', () {
      final caller = TestPlanCaller();
      final laps = [..._stint(1, tyre: 'Racing Soft', count: 4), ..._stint(2, test: 1, count: 10)];
      final call = caller.check(plan, laps, activeTestNumber: 1, currentStintNumber: 2, liveWearRemaining: 8)?.prompt;
      expect(call, contains('next stint test: Soft · 100% fuel · Map 1 · until 90% worn or fuel < 5% (about 30 laps)'));
    });
  });

  group('Boxington calls', () {
    final plan = TestPlan.fromBriefing(_briefing(['Racing Medium', 'Racing Soft']));

    test('calls "box" once when the live wear reaches the target, naming the next test', () {
      final caller = TestPlanCaller();
      final laps = _stint(1, test: 1, count: 10);
      String? check(double wear) =>
          caller.check(plan, laps, activeTestNumber: 1, currentStintNumber: 1, liveWearRemaining: wear)?.prompt;
      expect(check(20), isNull);
      final call = check(11);
      expect(call, contains('Stint Test 1 complete: tyres at 11% left'));
      expect(call, contains('move on to the next stint test'));
      expect(call, isNot(contains('box')));
      expect(call, contains('next stint test: Soft · 100% fuel · Map 1 · until 90% worn or fuel < 5%'));
      expect(check(9), isNull, reason: 'once only');
    });

    test('a worn reading left over from the previous stint does not end a test that has just started', () {
      final caller = TestPlanCaller();
      final previous = _stint(1, count: 25); // ended on worn tyres
      // Test 1 started in the garage: no lap of it yet, last reading 8%.
      expect(
        caller.check(plan, previous, activeTestNumber: 1, currentStintNumber: 1, liveWearRemaining: 8)?.prompt,
        isNull,
      );
      expect(TestPlanTracker.stopReason(plan.stints.first, null, liveWearRemaining: 8), isNull);
      // Once a lap of the test is done, the live reading counts.
      final withLap = [...previous, ..._stint(2, test: 1, count: 1)];
      expect(
        caller.check(plan, withLap, activeTestNumber: 1, currentStintNumber: 2, liveWearRemaining: 11)?.prompt,
        contains('complete'),
      );
    });

    test('says nothing when no test is running', () {
      final caller = TestPlanCaller();
      expect(
        caller.check(plan, _stint(1, count: 30), activeTestNumber: null, currentStintNumber: 1, liveWearRemaining: 10)?.prompt,
        isNull,
      );
    });
  });

  testWidgets("the practice log lists the plan with each test's status", (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final plan = TestPlan.fromBriefing(_briefing(['Racing Medium', 'Racing Soft']));
    await tester.pumpWidget(
      MaterialApp(
        home: PracticeLogScreen(
          laps: _stint(1, test: 1, count: 25),
          roundName: 'Round 5',
          testPlan: plan,
          activeTestNumber: 2,
          onClear: () {},
          onDeleteLap: (_) {},
        ),
      ),
    );
    expect(find.text('Stint Test 1: Medium · 100% fuel · Map 1 · until 90% worn or fuel < 5% (about 30 laps)'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.play_circle), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(2));
  });

  group('a wet race brief', () {
    RaceBriefing wet(String slots, {int laps = 26}) => RaceBriefing(
      trackName: 'Test',
      totalLaps: laps,
      startingFuelPercent: 100,
      availableTireCompounds: const ['Racing Hard', 'Racing Medium', 'Racing Soft', 'Intermediate', 'Heavy Wet'],
      wetOrChangeableWeather: true,
      weatherSlots: slots,
    );

    test('R06/R05/C03/S14/S04/R03/R04/R05: Wets vs Inters in R06 and R05, Inters vs Hards in R03 -- no dry long stints', () {
      final plan = TestPlan.fromBriefing(wet('R06/R05/C03/S14/S04/R03/R04/R05'));
      expect([for (final s in plan.stints) '${s.number} ${s.weather} ${s.compoundShort}'], [
        '1 R06 Wets',
        '2 R06 Inters',
        '3 R05 Inters', // carried over from the R06 pair
        '4 R05 Wets',
        '5 R03 Inters',
        '6 R03 Hard',
        '7 null Inters', // the full race test, on the strategy's start tyre
      ]);
      expect(plan.stints.last.kind, TestStintKind.race);
      expect(plan.stints.take(6).every((s) => s.kind == TestStintKind.wet && s.laps == TestPlan.wetLaps), isTrue);
      expect(plan.stints.first.target, 'Wets · R06 rain · 100% fuel · Map 1 · 4 laps');
      expect(plan.stints.first.purpose, 'Wets vs Inters in R06 Thick Cloud with Rain');
    });

    test('light rain only (R01/R02) is a dry race', () {
      final plan = TestPlan.fromBriefing(wet('R01/C03/R02/S04'));
      expect(plan.stints.any((s) => s.kind == TestStintKind.wet), isFalse);
      expect(plan.stints.first.kind, TestStintKind.long);
    });

    test('mostly dry with a shower: the dry long stints, then the wet pair', () {
      final plan = TestPlan.fromBriefing(wet('S01/S02/C03/S04/C05/R05/S06/S07'));
      expect(plan.stints.first.kind, TestStintKind.long);
      expect([for (final s in plan.stints.where((s) => s.kind == TestStintKind.wet)) '${s.weather} ${s.compoundShort}'],
          ['R05 Wets', 'R05 Inters']);
      expect([for (final s in plan.stints) s.number], [for (var i = 1; i <= plan.stints.length; i++) i]);
    });

    test('a wet test is done after its laps, and starting it puts its weather on the laps', () {
      final planned = TestPlan.fromBriefing(wet('R06/R05/C03/S14/S04/R03/R04/R05')).stints.first;
      expect(TestPlanTracker.stopReason(planned, StintSummary.fromLaps(_stint(1, test: 1, tyre: 'Heavy Wet', count: 3)).first), isNull);
      expect(TestPlanTracker.stopReason(planned, StintSummary.fromLaps(_stint(1, test: 1, tyre: 'Heavy Wet', count: 4)).first),
          '4 laps done');

      final logger = PracticeLapLogger()
        ..setWeather(planned.weather)
        ..startNewStint(testNumber: planned.number);
      expect(logger.currentWeather, 'R06');
      expect(logger.activeTestNumber, 1);
    });
  });

  group('the full race test', () {
    final plan = TestPlan.fromBriefing(_briefing(['Racing Medium', 'Racing Soft']), startCompound: 'Racing Medium');
    final race = plan.stints.last;

    test('is last: the race distance from the strategy\'s start tyre and fuel', () {
      expect(race.kind, TestStintKind.race);
      expect(race.laps, 26);
      expect(race.compound, 'Racing Medium');
    });

    test('carries on through its pit stops, and ends at the race distance', () {
      final logger = PracticeLapLogger();
      logger.startNewStint(testNumber: race.number, throughStops: true);
      var lap = 1;
      void drive(int n) {
        for (var i = 0; i < n; i++) {
          logger.update(_frame(lap++, 100 - lap * 2.0));
        }
      }

      drive(13);
      logger.startNewStint(automatic: true, pitStop: true); // the planned stop
      expect(logger.activeTestNumber, race.number, reason: 'still the race test after the stop');
      drive(14);
      final stints = {for (final l in logger.laps.where((l) => l.testNumber == race.number)) l.stintNumber};
      expect(stints, hasLength(2), reason: 'two stints, one test');
      expect(TestPlanTracker.raceLapsSoFar(logger.laps, race.number), greaterThanOrEqualTo(26));
      expect(TestPlanTracker.progress(plan, logger.laps).statuses.last, TestStatus.done);

      final caller = TestPlanCaller();
      expect(
        caller.check(plan, logger.laps, activeTestNumber: race.number, currentStintNumber: logger.currentStint)?.prompt,
        contains('full race distance done'),
      );
    });

    test("runs the strategy: its stops, each stint on that stint's map", () {
      // Round 6: Softs all race, Map 2 for the middle stint only.
      const stops = [
        PlannedPitStop(lap: 4, tireCompound: 'Racing Soft', reasoning: '', fuelMap: 2),
        PlannedPitStop(lap: 9, tireCompound: 'Racing Soft', reasoning: '', fuelMap: 1),
      ];
      final plan = TestPlan.fromBriefing(_briefing(['Racing Hard', 'Racing Soft']), startCompound: 'Racing Soft', raceStops: stops);
      final race = plan.stints.last;
      expect(race.target, 'Full race · 26 laps · start on Soft · 100% fuel · Map 1 · lap 4: box for Softs · Map 2 · lap 9: box for Softs · Map 1');
      expect(race.stintMaps, [1, 2, 1]);

      // Each stint's laps are logged on its map.
      final logger = PracticeLapLogger()
        ..startNewStint(testNumber: race.number, throughStops: true, testStintMaps: race.stintMaps);
      var lap = 1;
      void drive(int n) {
        for (var i = 0; i < n; i++) {
          logger.update(_frame(lap++, 100 - lap * 2.0));
        }
      }

      drive(5); // the first lap boundary only starts the count: 4 laps
      logger.startNewStint(automatic: true, pitStop: true);
      drive(5);
      logger.startNewStint(automatic: true, pitStop: true);
      drive(4);
      final byStint = <int, Set<int?>>{};
      for (final l in logger.laps.where((l) => l.testNumber == race.number)) {
        byStint.putIfAbsent(l.stintNumber, () => {}).add(l.fuelMap);
      }
      expect(byStint.values.toList(), [{1}, {2}, {1}]);
    });

    test('with a strategy of no stops it says so', () {
      final plan = TestPlan.fromBriefing(_briefing(['Racing Soft']), startCompound: 'Racing Soft', raceStops: const []);
      expect(plan.stints.last.target, endsWith('· no stops'));
    });

    test('a pit stop still ends any other test', () {
      final logger = PracticeLapLogger();
      logger.update(_frame(1, 100));
      logger.startNewStint(testNumber: 1);
      logger.update(_frame(2, 97));
      logger.startNewStint(automatic: true, pitStop: true);
      expect(logger.activeTestNumber, isNull);
    });

    test('short of the distance it stays to do', () {
      final logger = PracticeLapLogger();
      logger.startNewStint(testNumber: race.number, throughStops: true);
      for (var lap = 1; lap <= 10; lap++) {
        logger.update(_frame(lap, 100 - lap * 2.0));
      }
      logger.startNewStint(); // gave up: NEW STINT
      expect(TestPlanTracker.progress(plan, logger.laps).statuses.last, TestStatus.toDo);
    });
  });

  test('the tests resize to the fuel measured, without regenerating the strategy', () {
    final brief = RaceBriefing(
      trackName: 'Circuit de Sainte-Croix - C',
      totalLaps: 13,
      startingFuelPercent: 100,
      fuelConsumptionMultiplier: 4,
      availableTireCompounds: const ['Racing Hard', 'Racing Soft'],
    );
    // The strategy from scratch assumed 14.63%/lap: 6-lap long stints.
    const strategy = RaceStrategy(pitStops: [], startingTireCompound: 'Racing Soft', summary: '', assumedPercentPerLap: 14.63);
    List<int?> longLaps(TestPlan p) => [for (final s in p.stints) if (s.kind == TestStintKind.long) s.laps];
    expect(longLaps(TestPlan.forRound(brief, strategy, const [])), [6, 6]);
    // Test 1's Hard laps measure 19.3%/lap: a tank is 4 laps (half a lap kept back).
    final laps = [
      for (var i = 0; i < 5; i++)
        PracticeLapRecord(
          lapNumber: i + 1,
          lapTimeMs: 224000,
          tireCompound: 'Racing Hard',
          fuelPercentAtLapStart: 100 - i * 19.3,
          fuelPercentAtLapEnd: 100 - (i + 1) * 19.3,
          recordedAt: DateTime(2026),
          stintNumber: 1,
          testNumber: 1,
        ),
    ];
    final plan = TestPlan.forRound(brief, strategy, laps);
    expect(longLaps(plan), [4, 4]);
    final low = plan.stints.firstWhere((s) => s.kind == TestStintKind.lowFuel);
    expect(low.laps, 2);
  });
}
