// From a real session (Round 6, Sainte-Croix, x4 fuel): Stint Test 1 on
// Hards run for 5 laps and called complete, then 4 laps on Softs with no
// test Started -- they counted for nothing and Boxington said nothing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/models/test_plan.dart';
import 'package:boxbox/screens/practice_log_screen.dart';
import 'package:boxbox/services/practice_lap_logger.dart';
import 'package:boxbox/services/test_plan_tracker.dart';
import 'package:boxbox/services/stint_summary.dart';

const _brief = RaceBriefing(
  trackName: 'Sainte-Croix C',
  totalLaps: 13,
  startingFuelPercent: 100,
  fuelConsumptionMultiplier: 4,
  tyreWearMultiplier: 2,
  availableTireCompounds: ['Racing Hard', 'Racing Soft', 'Intermediate', 'Heavy Wet'],
);

// The laps' real times, in order.
const _times = [226155, 222108, 222656, 220373, 220955, 218060, 214819, 214525, 215062];

PracticeLapRecord _lap(int seq, String tyre, int stint, double f0, double f1, {int? test, bool done = false, double? wear}) => PracticeLapRecord(
  lapNumber: seq + 1,
  lapTimeMs: _times[seq],
  tireCompound: tyre,
  fuelPercentAtLapStart: f0,
  fuelPercentAtLapEnd: f1,
  tireWearPercent: wear,
  recordedAt: DateTime(2026, 11, 20, 16, 35).add(Duration(minutes: 4 * seq)),
  stintNumber: stint,
  testNumber: test,
  testTargetReached: done,
);

// Stint Test 1: Hards, 5 laps, 18.4%/lap, called complete on lap 5.
final _hards = [
  _lap(0, 'Racing Hard', 1, 99.7, 80.7, test: 1, wear: 100),
  _lap(1, 'Racing Hard', 1, 80.7, 62.1, test: 1, wear: 94.3),
  _lap(2, 'Racing Hard', 1, 62.1, 43.8, test: 1, wear: 91.4),
  _lap(3, 'Racing Hard', 1, 43.8, 25.4, test: 1, wear: 88.6),
  _lap(4, 'Racing Hard', 1, 25.4, 7.8, test: 1, done: true, wear: 85.7),
];

// Then Softs, no test Started.
final _softs = [
  _lap(5, 'Racing Soft', 2, 99.7, 80.9, wear: 91.7),
  _lap(6, 'Racing Soft', 2, 80.9, 61.5, wear: 85.7),
  _lap(7, 'Racing Soft', 2, 61.5, 42.1, wear: 77.1),
  _lap(8, 'Racing Soft', 2, 42.1, 22.5, wear: 69.4),
];

TestPlan _plan(List<PracticeLapRecord> laps) => TestPlan.forRound(_brief, null, laps);

void main() {
  test('on the fuel measured, a tank here is 5 laps -- as run (7.8% left)', () {
    expect(_plan(_hards).stints.first.laps, 5);
  });

  test('a done test shows the laps it ran, not the plan resized since', () {
    // Resized since (here to a heavier fuel figure: 3 laps a tank).
    final plan = TestPlan.fromBriefing(_brief, fuelPerLapPercent: 25);
    final test1 = plan.stints.first;
    expect(test1.laps, 3);
    final progress = TestPlanTracker.progress(plan, _hards);
    expect(progress.statuses.first, TestStatus.done, reason: 'called complete on lap 5');
    expect(progress.lapsFor(test1), (5, false));
    expect(progress.targetFor(test1), 'Hard · 100% fuel · Map 1 · 5 laps run');
    // A test still to do keeps the plan's laps.
    expect(progress.targetFor(plan.stints[1]), contains('${plan.stints[1].laps} laps (or until'));
  });

  test('a lap on a test\'s tyre with no test Started: Boxington says so, once a stint', () {
    final caller = TestPlanCaller();
    final laps = [..._hards, _softs.first];
    final plan = _plan(laps);
    final call = caller.check(plan, laps, activeTestNumber: null, currentStintNumber: 2);
    expect(call, isNotNull);
    expect(call!.completesTest, isFalse);
    expect(call.prompt, contains("isn't counting towards Stint Test 2"));
    expect(call.prompt, contains('START on Stint Test 2'));
    final more = [...laps, _softs[1]];
    expect(caller.check(plan, more, activeTestNumber: null, currentStintNumber: 2), isNull, reason: 'once a stint');
  });

  test('the test picked (not Started) is the one named', () {
    final laps = [..._hards, _softs.first];
    final plan = _plan(laps);
    final lowFuel = plan.stints.firstWhere((s) => s.kind == TestStintKind.lowFuel);
    final call = TestPlanCaller().check(plan, laps, activeTestNumber: null, currentStintNumber: 2, chosenTestNumber: lowFuel.number);
    expect(call!.prompt, contains('Stint Test ${lowFuel.number}'));
  });

  test('no call on a tyre no test still to do runs, or once a test is running', () {
    final hardsAgain = [..._hards, _lap(5, 'Racing Hard', 2, 99.7, 81, wear: 95)];
    expect(TestPlanCaller().check(_plan(hardsAgain), hardsAgain, activeTestNumber: null, currentStintNumber: 2), isNull,
        reason: 'the Hard test is done');
    final started = [..._hards, _lap(5, 'Racing Soft', 2, 99.7, 80.9, test: 2, wear: 91.7)];
    final call = TestPlanCaller().check(_plan(started), started, activeTestNumber: 2, currentStintNumber: 2);
    expect(call?.prompt ?? '', isNot(contains('no stint test was started')));
  });

  test('a stint run without Starting its test counts once the driver says which test it was', () {
    final logger = PracticeLapLogger()..seedWithPersistedLaps([..._hards, ..._softs]);
    var plan = _plan(logger.laps);
    expect(TestPlanTracker.progress(plan, logger.laps).statuses[1], TestStatus.toDo);
    logger.countLapsAsTest({for (final l in _softs) l.recordedAt}, 2);
    expect(logger.laps.where((l) => l.stintNumber == 2).map((l) => l.testNumber), everyElement(2));
    expect(logger.laps.where((l) => l.stintNumber == 1).map((l) => l.testNumber), everyElement(1), reason: 'the other stint untouched');
    plan = _plan(logger.laps);
    final progress = TestPlanTracker.progress(plan, logger.laps);
    // A tank is 5 laps (5% kept back): its 4 laps count, but fall a lap short.
    expect(plan.stints[1].laps, 5);
    expect(progress.statuses[1], TestStatus.toDo);
    expect(progress.matchedStints[1], isNull);
    // Its fifth lap would have done it.
    final soft = StintSummary.fromLaps(logger.laps).firstWhere((x) => x.stintNumber == 2);
    expect(TestPlanTracker.stopReason(plan.stints[1], soft), isNull);
  });

  test('a steady short stint is no drop-off: fuel-corrected slower, but not as run', () {
    // 20 Nov evening: Softs then Hards, 4 laps each, both called gone off
    // on lap 4 (the tile red, with no figure) -- the pace as run was flat,
    // the fuel correction (0.75 s a lap at x4) all of the "loss".
    PracticeLapRecord lap(int seq, String tyre, int stint, int ms, double f0) => PracticeLapRecord(
      lapNumber: seq + 1,
      lapTimeMs: ms,
      tireCompound: tyre,
      fuelPercentAtLapStart: f0,
      fuelPercentAtLapEnd: f0 - 18.6,
      recordedAt: DateTime(2026, 11, 20, 19, 20).add(Duration(minutes: 4 * seq)),
      stintNumber: stint,
    );
    final laps = [
      lap(0, 'Racing Soft', 1, 217667, 99.7),
      lap(1, 'Racing Soft', 1, 214546, 80.0),
      lap(2, 'Racing Soft', 1, 215432, 60.6),
      lap(3, 'Racing Soft', 1, 214796, 41.5),
      lap(4, 'Racing Hard', 2, 223623, 99.7),
      lap(5, 'Racing Hard', 2, 220380, 80.7),
      lap(6, 'Racing Hard', 2, 220423, 62.1),
      lap(7, 'Racing Hard', 2, 219990, 43.8),
    ];
    for (final s in StintSummary.fromLaps(laps)) {
      expect(s.tyreDropOff, isNull, reason: 'stint ${s.stintNumber}');
    }
    // A real fall in pace on a short stint is still called.
    final fading = [
      lap(0, 'Racing Soft', 1, 214800, 99.7),
      lap(1, 'Racing Soft', 1, 214546, 80.0),
      lap(2, 'Racing Soft', 1, 214700, 60.6),
      lap(3, 'Racing Soft', 1, 216900, 41.5),
      lap(4, 'Racing Soft', 1, 217400, 22.9),
    ];
    expect(StintSummary.fromLaps(fading).single.tyreDropOff?.fromLapNumber, 4);
  });

  test('a completed test: the instant clip says it, Boxington only adds what\'s next', () {
    final caller = TestPlanCaller();
    final plan = _plan(_hards);
    final call = caller.check(plan, _hards, activeTestNumber: 1, currentStintNumber: 1);
    expect(call?.completesTest, isTrue);
    expect(call!.prompt, contains('You have just said "${TestPlanCaller.completeClip}"'));
    expect(call.prompt, contains('the next stint test: Soft'));
  });

  testWidgets('the log offers COUNT AS TEST on a stint with no test, and counts it', (tester) async {
    final laps = [..._hards, ..._softs];
    (Set<DateTime>, int)? counted;
    await tester.pumpWidget(MaterialApp(
      home: PracticeLogScreen(
        laps: List.unmodifiable(laps),
        testPlan: _plan(laps),
        onClear: () {},
        onDeleteLap: (_) {},
        onCountStintAsTest: (at, test) => counted = (at, test),
      ),
    ));
    await tester.scrollUntilVisible(find.text('COUNT AS TEST'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('COUNT AS TEST'), findsOneWidget, reason: 'only the Soft stint: the Hard one is Stint Test 1');
    await tester.tap(find.text('COUNT AS TEST'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('Stint Test 2:')));
    await tester.pumpAndSettle();
    expect(counted?.$2, 2);
    expect(counted?.$1, {for (final l in _softs) l.recordedAt});
    expect(find.text('COUNT AS TEST'), findsNothing);
  });
}
