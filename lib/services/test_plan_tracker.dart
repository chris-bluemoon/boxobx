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

  /// The planned stint's target, with the expected lap count when known,
  /// e.g. "Soft · 100% fuel · until 70% worn (about 12 laps)".
  String targetFor(PlannedTestStint planned) {
    final laps = expectedLaps[planned.number - 1];
    return laps == null ? planned.target : '${planned.target} (about $laps laps)';
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
  /// Long stints also end when fuel gets this low...
  static const double fuelOutPercent = 5;

  /// ...or when the latest lap is this much slower than the stint's best.
  static const double dropOffLimitMs = 1500;

  /// Wear readings are noisy; within this of the target counts as reached.
  static const double wearTolerancePercent = 2;

  /// Why a stint running [planned] should stop now, or null if it
  /// shouldn't yet. [stint] is null until its first lap completes;
  /// [liveWearRemaining]/[liveFuelPercent] are the current readings, so
  /// a long stint can end mid-lap.
  static String? stopReason(
    PlannedTestStint planned,
    StintSummary? stint, {
    double? liveWearRemaining,
    double? liveFuelPercent,
  }) {
    switch (planned.kind) {
      case TestStintKind.lowFuel:
        final laps = stint?.lapCount ?? 0;
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
        final fuel = liveFuelPercent ?? stint?.laps.last.fuelPercentAtLapEnd;
        if (fuel != null && fuel <= fuelOutPercent) return 'fuel nearly out (${fuel.toStringAsFixed(0)}%)';
        final dropOff = stint == null ? null : _latestLapOffBestMs(stint);
        if (dropOff != null && dropOff >= dropOffLimitMs) {
          return 'lap times ${(dropOff / 1000).toStringAsFixed(1)}s off the stint best';
        }
        return null;
    }
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

  static double? _latestLapOffBestMs(StintSummary stint) {
    final clean = stint.laps.where((l) => !l.isPitLap).toList();
    if (clean.length < 3) return null;
    final best = clean.map((l) => l.lapTimeMs).reduce((a, b) => a < b ? a : b);
    return (clean.last.lapTimeMs - best).toDouble();
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
      if (planned.number == activeTestNumber) {
        // The latest stint tagged with this test is the one running.
        statuses.add(TestStatus.inProgress);
        matched.add(tagged.isEmpty ? null : tagged.last);
        continue;
      }
      final done = tagged.where((s) => s.testTargetReached || stopReason(planned, s) != null).firstOrNull;
      statuses.add(done == null ? TestStatus.toDo : TestStatus.done);
      matched.add(done);
    }
    return TestPlanProgress(plan, statuses, matched, [
      for (final planned in plan.stints) expectedLaps(planned, newestFirst),
    ]);
  }
}

/// Boxington's test-plan call (Practice Mode): once per test stint, when
/// the running test reaches its target.
class TestPlanCaller {
  /// The (test, stint) last called, so each run is called once.
  (int, int)? _called;

  void reset() => _called = null;

  String? check(
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
    final reason = TestPlanTracker.stopReason(
      planned,
      progress.matchedStints[index],
      liveWearRemaining: liveWearRemaining,
      liveFuelPercent: liveFuelPercent,
    );
    final key = (planned.number, currentStintNumber);
    if (reason == null || _called == key) return null;
    _called = key;

    final following = progress.statuses.indexWhere((s) => s == TestStatus.toDo, index + 1);
    final nextTest = following < 0 ? null : plan.stints[following];
    return 'Test ${planned.number} complete: $reason. The data is logged. '
        '${nextTest == null ? 'Tell the driver that completes the test plan -- come in.' : 'Tell the driver to come in and move on to the next test: ${progress.targetFor(nextTest)}.'}'
        ' One short transmission.';
  }
}
