import '../models/practice_lap_record.dart';
import '../models/test_plan.dart';
import 'stint_summary.dart';

enum TestStatus { done, inProgress, toDo }

/// Where the driver is in the test plan.
class TestPlanProgress {
  final TestPlan plan;

  /// Status of each planned stint, in plan order.
  final List<TestStatus> statuses;

  /// The logged stint for each planned stint: the one that completed it,
  /// or the one running now (null if not started, or started but no lap
  /// completed yet).
  final List<StintSummary?> matchedStints;

  /// For each planned stint, roughly how many laps it should take, once
  /// that compound's wear rate has been measured (null until then, and
  /// for low-fuel stints, which are a fixed lap count).
  final List<int?> expectedLaps;

  const TestPlanProgress(this.plan, this.statuses, this.matchedStints, this.expectedLaps);

  /// The planned stint's target, with the tyres' expected laps when
  /// they're the limit (see PlannedTestStint.targetWith), e.g.
  /// "Soft · 100% fuel · Map 1 · 5 laps (or until 90% worn or fuel < 5%)".
  String targetFor(PlannedTestStint planned) {
    final i = planned.number - 1;
    // Done: the map its laps were run on (Map 1 when they don't say).
    final ran = statuses[i] == TestStatus.done ? (matchedStints[i]?.laps.first.fuelMap ?? 1) : null;
    return planned.targetWith(expectedLaps[i], ranOnMap: ran);
  }

  /// The laps [planned] runs to, and whether that's only an estimate:
  /// its planned laps (a tank, the race, a short test's count), or --
  /// when the tyres should go first -- their expected laps (~). Null
  /// when neither is known.
  (int, bool)? lapsFor(PlannedTestStint planned) {
    final wear = expectedLaps[planned.number - 1];
    final laps = planned.laps;
    if (laps != null && (wear == null || wear >= laps)) return (laps, false);
    return wear == null ? null : (wear, true);
  }

  /// The test running now, if any.
  PlannedTestStint? get running {
    final i = statuses.indexOf(TestStatus.inProgress);
    return i < 0 ? null : plan.stints[i];
  }

  /// The first planned stint that isn't done yet, or null when the plan
  /// is complete.
  PlannedTestStint? get next {
    for (var i = 0; i < plan.stints.length; i++) {
      if (statuses[i] != TestStatus.done) return plan.stints[i];
    }
    return null;
  }

  bool get complete => plan.stints.isNotEmpty && next == null;
}

/// Tracks the driver through a [TestPlan]. The driver says which test
/// each stint is for (PracticeLapRecord.testNumber, set from the
/// dashboard) and the app trusts that: nothing is inferred from the tyre
/// or fuel, and only stints started as a test count towards one.
class TestPlanTracker {
  /// Long stints end at their laps (one tank, or the race distance --
  /// see TestPlan.fromBriefing), at the wear target, when fuel gets this
  /// low...
  static const double fuelOutPercent = TestPlan.fuelOutPercent;

  // ...or once the tyres have dropped off (StintSummary.tyreDropOff).

  /// Wear readings are noisy; within this of the target counts as reached.
  static const double wearTolerancePercent = 2;

  /// Why a stint running [planned] should stop now, or null if it
  /// shouldn't yet. [stint] is null until its first lap completes;
  /// [liveWearRemaining]/[liveFuelPercent] are the current readings, so
  /// a long stint can end mid-lap.
  ///
  /// [raceLaps]: for the full race test, the laps run so far across all
  /// its stints (it carries on through the pit stops).
  static String? stopReason(
    PlannedTestStint planned,
    StintSummary? stint, {
    double? liveWearRemaining,
    double? liveFuelPercent,
    int? raceLaps,
  }) {
    switch (planned.kind) {
      case TestStintKind.race:
        final laps = raceLaps ?? stint?.laps.length ?? 0;
        return laps >= planned.laps! ? 'full race distance done (${planned.laps} laps)' : null;
      case TestStintKind.lowFuel || TestStintKind.wet || TestStintKind.fuelMap:
        final laps = stint?.lapsDriven ?? 0;
        return laps >= planned.laps! ? '${planned.laps} laps done' : null;
      case TestStintKind.long:
        final target = planned.stopAtWearRemainingPercent!;
        // The live wear reading is only trusted once the test stint has a
        // completed lap: when a test is started in the garage, the last
        // reading is still the PREVIOUS stint's worn tyres (the relay
        // can't see the HUD from the menus), which would otherwise end
        // the test the moment it starts.
        final wear = stint == null ? null : (liveWearRemaining ?? stint.latestTyreWearPercent);
        if (wear != null && wear <= target + wearTolerancePercent) {
          return 'tyres at ${wear.toStringAsFixed(0)}% left';
        }
        // Laps driven, off-pace ones included: the driver did the lap.
        if (planned.laps case final laps? when (stint?.lapsDriven ?? 0) >= laps) {
          return planned.lapsAreRaceDistance ? 'race distance done ($laps laps)' : 'a full tank done ($laps laps)';
        }
        final fuel = liveFuelPercent ?? stint?.laps.last.fuelPercentAtLapEnd;
        if (fuel != null && fuel <= fuelOutPercent) return 'fuel nearly out (${fuel.toStringAsFixed(0)}%)';
        final dropOff = stint?.tyreDropOff;
        if (dropOff != null) {
          return 'tyres dropped off from lap ${dropOff.fromLapNumber}, '
              '${(dropOff.lossMs / 1000).toStringAsFixed(1)}s a lap off peak pace';
        }
        return null;
    }
  }

  /// A full race test's attempts: its stints grouped into runs of
  /// consecutive stint numbers (oldest first).
  static List<List<StintSummary>> raceRuns(List<StintSummary> oldestFirst) {
    final runs = <List<StintSummary>>[];
    for (final s in oldestFirst) {
      if (runs.isNotEmpty && runs.last.last.stintNumber == s.stintNumber - 1) {
        runs.last.add(s);
      } else {
        runs.add([s]);
      }
    }
    return runs;
  }

  static int lapsIn(List<StintSummary> run) => run.fold(0, (n, s) => n + s.laps.length);

  /// The laps run so far in the current attempt at the full race test
  /// [testNumber] (0 if none).
  static int raceLapsSoFar(List<PracticeLapRecord> laps, int testNumber) {
    final tagged = StintSummary.fromLaps(laps).reversed.where((s) => s.stintNumber != 0 && s.testNumber == testNumber).toList();
    final runs = raceRuns(tagged);
    return runs.isEmpty ? 0 : lapsIn(runs.last);
  }

  /// Laps from fresh tyres to [planned]'s wear target, from the most
  /// recent stint on the same compound with a measured wear rate (any
  /// stint, test or not -- it's only an estimate). Null if none yet.
  static int? expectedLaps(PlannedTestStint planned, List<StintSummary> stints) {
    if (planned.kind != TestStintKind.long) return null;
    for (final stint in stints) {
      if (stint.stintNumber == 0 || stint.tyreCompound != planned.compound) continue;
      final perLap = stint.tyreWearPerLapPercent;
      if (perLap == null) continue;
      return ((100 - planned.stopAtWearRemainingPercent!) / perLap).round();
    }
    return null;
  }

  /// Each planned test is in progress while it's the [activeTestNumber];
  /// otherwise done once any stint tagged with its number reached the
  /// target, else to do (an attempt that stopped short doesn't count).
  static TestPlanProgress progress(TestPlan plan, List<PracticeLapRecord> laps, {int? activeTestNumber}) {
    final newestFirst = StintSummary.fromLaps(laps);
    final stints = newestFirst.reversed.toList(); // oldest first
    final statuses = <TestStatus>[];
    final matched = <StintSummary?>[];

    for (final planned in plan.stints) {
      final tagged = stints.where((s) => s.stintNumber != 0 && s.testNumber == planned.number).toList();
      if (planned.kind == TestStintKind.race) {
        // One attempt is a run of back-to-back stints (split by its stops).
        final runs = raceRuns(tagged);
        if (planned.number == activeTestNumber) {
          statuses.add(TestStatus.inProgress);
          matched.add(tagged.isEmpty ? null : tagged.last);
          continue;
        }
        final done = runs.where((run) => run.any((s) => s.testTargetReached) || stopReason(planned, run.last, raceLaps: lapsIn(run)) != null);
        statuses.add(done.isEmpty ? TestStatus.toDo : TestStatus.done);
        matched.add(done.isEmpty ? null : done.first.last);
        continue;
      }
      // Only laps on the test's own tyre count (the HUD may read another:
      // the wrong tyre was fitted).
      final onTyre = [
        for (final s in tagged)
          if (s.laps.where((l) => l.tireCompound == planned.compound).toList() case final laps when laps.isNotEmpty)
            StintSummary.fromLaps(laps).first,
      ];
      if (planned.number == activeTestNumber) {
        // The latest stint tagged with this test is the one running.
        statuses.add(TestStatus.inProgress);
        matched.add(onTyre.isEmpty || onTyre.last.stintNumber != tagged.last.stintNumber ? null : onTyre.last);
        continue;
      }
      final done = onTyre.where((s) => s.testTargetReached || stopReason(planned, s) != null).firstOrNull;
      statuses.add(done == null ? TestStatus.toDo : TestStatus.done);
      matched.add(done);
    }
    return TestPlanProgress(plan, statuses, matched, [
      for (final planned in plan.stints) expectedLaps(planned, newestFirst),
    ]);
  }
}

/// One of Boxington's test-plan calls: [prompt] for him to say, and
/// whether it ends the running test (the target's reached) or is a
/// heads-up that keeps it going (the wrong tyre).
class TestPlanCall {
  final String prompt;
  final bool completesTest;
  const TestPlanCall(this.prompt, {required this.completesTest});
}

/// Boxington's test-plan calls (Practice Mode): once per test stint, when
/// the running test reaches its target, and once a stint when it's on
/// the wrong tyre.
class TestPlanCaller {
  /// The (test, stint) last called, so each run is called once.
  (int, int)? _called;

  /// The (test, stint) last told it's on the wrong tyre.
  (int, int)? _wrongTyreCalled;

  void reset() {
    _called = null;
    _wrongTyreCalled = null;
  }

  TestPlanCall? check(
    TestPlan plan,
    List<PracticeLapRecord> laps, {
    required int? activeTestNumber,
    required int currentStintNumber,
    double? liveWearRemaining,
    double? liveFuelPercent,
  }) {
    if (activeTestNumber == null) return null;
    final progress = TestPlanTracker.progress(plan, laps, activeTestNumber: activeTestNumber);
    final index = progress.statuses.indexOf(TestStatus.inProgress);
    if (index < 0) return null;

    final planned = plan.stints[index];

    // The lap just done was on another tyre than the test's: it doesn't
    // count -- say so once a stint.
    final last = laps.lastOrNull;
    if (planned.kind != TestStintKind.race &&
        last != null &&
        last.testNumber == planned.number &&
        last.stintNumber == currentStintNumber &&
        last.tireCompound != planned.compound) {
      if (_wrongTyreCalled == (planned.number, currentStintNumber)) return null;
      _wrongTyreCalled = (planned.number, currentStintNumber);
      return TestPlanCall(
        'Stint Test ${planned.number} is on ${planned.compound}, but the car is on ${last.tireCompound}: '
        "these laps don't count towards it. Tell the driver to box and fit ${planned.compoundShort} -- the test "
        'carries on after the stop. One short transmission.',
        completesTest: false,
      );
    }

    final reason = TestPlanTracker.stopReason(
      planned,
      progress.matchedStints[index],
      liveWearRemaining: liveWearRemaining,
      liveFuelPercent: liveFuelPercent,
      raceLaps: planned.kind == TestStintKind.race ? TestPlanTracker.raceLapsSoFar(laps, planned.number) : null,
    );

    final key = (planned.number, currentStintNumber);
    if (reason == null || _called == key) return null;
    _called = key;

    final following = progress.statuses.indexWhere((s) => s == TestStatus.toDo, index + 1);
    final nextTest = following < 0 ? null : plan.stints[following];
    return TestPlanCall(
      'Stint Test ${planned.number} complete: $reason. The data is logged. '
      '${nextTest == null ? 'Tell the driver that completes the stint tests -- come in.' : 'Tell the driver to come in and move on to the next stint test: ${progress.targetFor(nextTest)}.'}'
      ' One short transmission.',
      completesTest: true,
    );
  }
}
