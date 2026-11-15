import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:boxbox/models/app_mode.dart';
import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/models/time_trial_lap.dart';
import 'package:boxbox/services/fuel_predictor.dart';
import 'package:boxbox/services/fused_race_state_manager.dart';
import 'package:boxbox/services/hud_ocr_service.dart';
import 'package:boxbox/services/saved_briefing_store.dart';
import 'package:boxbox/services/sector_calculator.dart';
import 'package:boxbox/services/telemetry_udp_service.dart';
import 'package:boxbox/services/time_trial_logger.dart';
import 'package:boxbox/services/time_trial_store.dart';

TelemetryFrame _frame(int lap, {int lastLapTimeMs = 90000, double fuel = 50}) => TelemetryFrame(
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
  lastLapTimeMs: lap == 1 ? -1 : lastLapTimeMs,
);

FusedRaceStateManager _manager() => FusedRaceStateManager(
  telemetryService: TelemetryUdpService(),
  hudService: HudOcrService(),
  sectorCalculator: SectorCalculator(),
  fuelPredictor: FuelPredictor(),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the three modes and what each turns on', () {
    expect(AppMode.values.map((m) => m.label), ['RACE MODE', 'PRACTICE', 'TIME TRIALING']);
    expect(AppMode.fromName('timeTrial'), AppMode.timeTrial);
    expect(AppMode.fromName(null), AppMode.practice);
    const tt = AppMode.timeTrial;
    expect([tt.pitCalls, tt.rivalCallouts, tt.opponentPitCallouts, tt.trafficChip, tt.testPlan], everyElement(isFalse));
    expect(tt.logsTimeTrialLaps, isTrue);
    expect(tt.logsStintLaps, isFalse);
    expect(AppMode.race.logsStintLaps && AppMode.practice.logsStintLaps, isTrue);
  });

  test('TimeTrialLogger records each completed lap with its tyre', () {
    final logger = TimeTrialLogger();
    expect(logger.update(_frame(1), tireCompound: 'Racing Soft'), isFalse);
    expect(logger.update(_frame(2, lastLapTimeMs: 89950), tireCompound: 'Racing Soft'), isTrue);
    expect(logger.update(_frame(2), tireCompound: 'Racing Soft'), isFalse);
    logger.update(_frame(3, lastLapTimeMs: 90400), tireCompound: 'Racing Soft');
    expect(logger.laps.map((l) => l.lapTimeMs), [89950, 90400]);
    expect(TimeTrialLap.best(logger.laps)!.lapTimeMs, 89950);
    expect(TimeTrialLap.format(89950), '1:29.950');
  });

  test('in Time Trialing, laps go to the time-trial log, not the stints, and are saved', () async {
    final manager = _manager()..setMode(AppMode.timeTrial);
    manager.handleTelemetryFrame(_frame(1));
    manager.handleTelemetryFrame(_frame(2, lastLapTimeMs: 89950));
    manager.handleTelemetryFrame(_frame(3, lastLapTimeMs: 90400));
    await Future<void>.delayed(Duration.zero);

    expect(manager.current.timeTrialLaps, hasLength(2));
    expect(manager.current.practiceLaps, isEmpty);
    expect(await TimeTrialStore.load(), hasLength(2));

    // Back in Practice, laps go to the stints again.
    manager.setMode(AppMode.practice);
    manager.handleTelemetryFrame(_frame(4, lastLapTimeMs: 91000));
    manager.handleTelemetryFrame(_frame(5, lastLapTimeMs: 91000));
    expect(manager.current.practiceLaps, isNotEmpty);
    expect(manager.current.timeTrialLaps, hasLength(2));
  });

  test('time-trial laps survive a restart; one can be deleted; all can be cleared', () async {
    await TimeTrialStore.save([
      TimeTrialLap(lapTimeMs: 89950, tireCompound: 'Racing Soft', recordedAt: DateTime(2026, 1, 1)),
      TimeTrialLap(lapTimeMs: 90400, tireCompound: 'Racing Soft', recordedAt: DateTime(2026, 1, 2)),
    ]);
    final manager = _manager();
    await manager.loadPersistedData();
    expect(manager.current.timeTrialLaps, hasLength(2));

    await manager.removeTimeTrialLap(DateTime(2026, 1, 1));
    expect(manager.current.timeTrialLaps.single.lapTimeMs, 90400);
    expect(await TimeTrialStore.load(), hasLength(1));

    await manager.clearTimeTrialLaps();
    expect(await TimeTrialStore.load(), isEmpty);
  });

  test("saving a new round starts an empty time-trial log, keeping the old round's", () async {
    final briefing = RaceBriefing(
      trackName: 'Test',
      totalLaps: 20,
      startingFuelPercent: 100,
      availableTireCompounds: const ['Racing Soft'],
    );
    await SavedBriefingStore.save(name: 'Round 5', briefing: briefing);
    await TimeTrialStore.save([TimeTrialLap(lapTimeMs: 1, tireCompound: 'x', recordedAt: DateTime(2026))]);
    await SavedBriefingStore.save(name: 'Round 5', briefing: briefing);
    expect(await TimeTrialStore.load(), hasLength(1), reason: 'same round keeps them');
    await SavedBriefingStore.save(name: 'Round 6', briefing: briefing);
    expect(await TimeTrialStore.load(), isEmpty);
    await SavedBriefingStore.save(name: 'Round 5', briefing: briefing);
    expect(await TimeTrialStore.load(), hasLength(1));
  });

  test("changing round swaps the laps in memory for the new round's", () async {
    final briefing = RaceBriefing(
      trackName: 'Test',
      totalLaps: 20,
      startingFuelPercent: 100,
      availableTireCompounds: const ['Racing Soft'],
    );
    await SavedBriefingStore.save(name: 'Round 5', briefing: briefing);
    final manager = _manager()
      ..setRound('Round 5')
      ..setMode(AppMode.timeTrial);
    manager.handleTelemetryFrame(_frame(1));
    manager.handleTelemetryFrame(_frame(2, lastLapTimeMs: 89950));
    expect(manager.current.timeTrialLaps, hasLength(1));

    await SavedBriefingStore.save(name: 'Round 6', briefing: briefing);
    manager.setRound('Round 6');
    await manager.reloadRoundLaps();
    expect(manager.current.timeTrialLaps, isEmpty);

    // Round 6's first lap doesn't drag Round 5's along with it.
    manager.handleTelemetryFrame(_frame(2));
    manager.handleTelemetryFrame(_frame(3, lastLapTimeMs: 90400));
    await manager.reloadRoundLaps();
    expect(manager.current.timeTrialLaps.map((l) => l.lapTimeMs), [90400]);
  });

  test('Boxington gets the time-trial best and how the last lap compares', () {
    final manager = _manager()..setMode(AppMode.timeTrial);
    manager.handleTelemetryFrame(_frame(1));
    manager.handleTelemetryFrame(_frame(2, lastLapTimeMs: 89950));
    manager.setMode(AppMode.race);
    manager.handleTelemetryFrame(_frame(3, lastLapTimeMs: 91200));
    final context = manager.current.toPromptContext();
    expect(context['timeTrialBestLap'], '1:29.950');
    expect(context['lastLapVsTimeTrialBestSeconds'], '1.25');
  });
}
