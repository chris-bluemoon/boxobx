// Drives FusedRaceStateManager's frame handling directly (no sockets)
// to cover how GT7's status flags, car ID and pit detection flow into
// the fused state.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:boxbox/models/app_mode.dart';
import 'package:boxbox/models/fused_race_state.dart';
import 'package:boxbox/models/hud_overlay_data.dart';
import 'package:boxbox/models/power_band_config.dart';
import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/services/fuel_predictor.dart';
import 'package:boxbox/services/fused_race_state_manager.dart';
import 'package:boxbox/services/hud_ocr_service.dart';
import 'package:boxbox/services/sector_calculator.dart';
import 'package:boxbox/services/telemetry_udp_service.dart';

const _onTrack = TelemetryFlags.carOnTrack;

TelemetryFrame _frame({
  required int lap,
  required double fuel,
  int lastLapTimeMs = -1,
  int flags = _onTrack,
  double speedKmh = 200,
  int carCode = 0,
}) =>
    TelemetryFrame(
      rpm: 6000,
      speedKmh: speedKmh,
      gear: 4,
      posX: 0,
      posY: 0,
      posZ: 0,
      lapDistance: 0,
      trackLength: 0,
      fuelPercent: fuel,
      tireTemps: const [80, 80, 80, 80],
      currentLap: lap,
      lastLapTimeMs: lastLapTimeMs,
      flags: flags,
      carCode: carCode,
      minAlertRpm: carCode == 0 ? 0 : 7000,
      maxAlertRpm: carCode == 0 ? 0 : 8000,
    );

FusedRaceStateManager _manager() => FusedRaceStateManager(
      telemetryService: TelemetryUdpService(),
      hudService: HudOcrService(),
      sectorCalculator: SectorCalculator(),
      fuelPredictor: FuelPredictor(),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('before GT7 ever reports "car on track", frames are treated as driving (old behaviour)', () {
    final manager = _manager();
    manager.handleTelemetryFrame(_frame(lap: 1, fuel: 100, flags: 0));
    manager.handleTelemetryFrame(_frame(lap: 2, fuel: 97, lastLapTimeMs: 90000, flags: 0));

    expect(manager.current.practiceLaps, hasLength(1));
    expect(manager.current.sessionPhase, SessionPhase.unknown);
  });

  test('a replay (GT7 never says the car is on track) still sees the pit stop', () {
    // Recorded from a GT7 replay: flags 0x198 at 190 km/h, carOnTrack never set.
    const replay = 0x198;
    final manager = _manager();
    var fuel = 100.0;
    manager.handleTelemetryFrame(_frame(lap: 1, fuel: fuel, flags: replay));
    for (var lap = 2; lap <= 9; lap++) {
      fuel -= 4.4;
      manager.handleTelemetryFrame(_frame(lap: lap, fuel: fuel, lastLapTimeMs: 96000, flags: replay));
    }
    manager.handleTelemetryFrame(_frame(lap: 9, fuel: fuel, speedKmh: 0, flags: replay));
    manager.handleTelemetryFrame(_frame(lap: 9, fuel: fuel + 30, speedKmh: 0, flags: replay));
    expect(manager.pitStopTracker.stopCount, 1);
    expect(manager.pitStopTracker.pitLaps, {9, 10});
  });

  test('paused frames are shown but not counted', () {
    final manager = _manager();
    manager.handleTelemetryFrame(_frame(lap: 1, fuel: 100));
    manager.handleTelemetryFrame(_frame(lap: 2, fuel: 97, lastLapTimeMs: 90000, flags: _onTrack | TelemetryFlags.paused));

    expect(manager.current.sessionPhase, SessionPhase.paused);
    expect(manager.current.telemetry.currentLap, 2);
    expect(manager.current.practiceLaps, isEmpty);
  });

  test('leaving the track for good ends the session: predictors reset, laps kept, display blanked', () async {
    final manager = _manager();
    var clock = DateTime(2026, 11, 16, 15);
    manager.now = () => clock;
    var sessionsEnded = 0;
    manager.sessionEnded.listen((_) => sessionsEnded++);

    manager.handleTelemetryFrame(_frame(lap: 1, fuel: 100));
    manager.handleTelemetryFrame(_frame(lap: 2, fuel: 97, lastLapTimeMs: 90000));
    manager.handleTelemetryFrame(_frame(lap: 3, fuel: 94, lastLapTimeMs: 90000));
    expect(manager.current.fuelPrediction.hasEnoughData, isTrue);

    // Back to the menu: GT7 keeps sending lap 3 values, but off track.
    manager.handleTelemetryFrame(_frame(lap: 3, fuel: 94, flags: 0));
    manager.handleTelemetryFrame(_frame(lap: 3, fuel: 94, flags: TelemetryFlags.loadingOrProcessing));
    await Future<void>.delayed(Duration.zero);
    expect(manager.current.sessionPhase, SessionPhase.offTrack);
    expect(sessionsEnded, 0, reason: 'could be a pit stop: not ended yet');

    clock = clock.add(FusedRaceStateManager.offTrackEndsSession);
    manager.handleTelemetryFrame(_frame(lap: 3, fuel: 94, flags: 0));
    await Future<void>.delayed(Duration.zero);

    expect(sessionsEnded, 1);
    expect(manager.current.sessionPhase, SessionPhase.offTrack);
    expect(manager.current.telemetry.rpm, 0);
    expect(manager.current.fuelPrediction.hasEnoughData, isFalse);
    expect(manager.current.practiceLaps, hasLength(2));

    // A new session starts on lap 1 and appends to the log.
    manager.handleTelemetryFrame(_frame(lap: 1, fuel: 100));
    manager.handleTelemetryFrame(_frame(lap: 2, fuel: 97, lastLapTimeMs: 89000));
    expect(manager.current.practiceLaps, hasLength(3));
    expect(manager.current.sessionPhase, SessionPhase.driving);
  });

  test('the car GT7 reports selects the power band', () {
    final manager = _manager();
    manager.handleTelemetryFrame(_frame(lap: 1, fuel: 100, carCode: 3218));
    expect(manager.current.powerBand, PowerBandConfig.bmwM6Gt3Endurance);

    manager.handleTelemetryFrame(_frame(lap: 1, fuel: 100, carCode: 9999));
    expect(manager.current.powerBand.overRevRpm, 8000);
    expect(manager.shiftHistoryTracker.config.overRevRpm, 8000);
    expect(manager.practiceLapLogger.powerBandConfig.overRevRpm, 8000);
  });

  test('a pit stop flags the affected laps and starts a new stint', () async {
    final manager = _manager();
    var fuel = 100.0;
    manager.handleTelemetryFrame(_frame(lap: 1, fuel: fuel));
    for (var lap = 2; lap <= 6; lap++) {
      fuel -= 3;
      manager.handleTelemetryFrame(_frame(lap: lap, fuel: fuel, lastLapTimeMs: 90000));
    }
    // Refuel on lap 6.
    fuel += 30;
    manager.handleTelemetryFrame(_frame(lap: 6, fuel: fuel, speedKmh: 0));
    manager.handleTelemetryFrame(_frame(lap: 7, fuel: fuel, lastLapTimeMs: 112000));
    manager.handleTelemetryFrame(_frame(lap: 8, fuel: fuel - 3, lastLapTimeMs: 94000));
    await Future<void>.delayed(Duration.zero);

    final laps = manager.current.practiceLaps;
    // Logged laps 1..7 correspond to game laps 1..7; laps 6 and 7 are pit laps.
    expect(laps.where((l) => l.isPitLap).map((l) => l.lapNumber), [6, 7]);
    // The out-lap begins stint 2 (new fuel).
    expect(laps.first.stintNumber, 1);
    expect(laps.last.stintNumber, 2);
  });

  test('opponent pit stops are logged with our lap, announced, and cleared when the session ends', () async {
    final manager = _manager();
    final announced = <String>[];
    manager.opponentPitted.listen((stops) => announced.addAll(stops.map((s) => s.driver)));

    manager.handleTelemetryFrame(_frame(lap: 7, fuel: 60));
    manager.handleHudData(HudOverlayData.fromMap({
      'driversInPit': {
        'Daywalkar86': {'position': 2, 'tyre': 'S', 'fuel': 57},
      },
    }));
    await Future<void>.delayed(Duration.zero);

    expect(announced, ['Daywalkar86']);
    expect(manager.current.opponentPitStops.single.ourLap, 7);
    expect(manager.current.toPromptContext()['opponentPitStops'], [
      {'driver': 'Daywalkar86', 'position': 2, 'ourLap': 7, 'tyre': 'softs', 'fuelAdded': 57},
    ]);

    manager.handleTelemetryFrame(_frame(lap: 7, fuel: 60, flags: 0));
    // A new race: the lap counter starts again.
    manager.handleTelemetryFrame(_frame(lap: 1, fuel: 100));
    expect(manager.current.opponentPitStops, isEmpty);
  });

  test('start/finish is learned from where our map marker is when the lap ticks over', () {
    final manager = _manager();
    HudOverlayData hudAt(double progress) => HudOverlayData.fromMap({
          'traffic': {'trackReady': true, 'playerLapProgress': progress, 'lapSeconds': 100.0, 'cars': []},
        });

    manager.handleTelemetryFrame(_frame(lap: 3, fuel: 60));
    manager.handleHudData(hudAt(990.0));
    manager.handleTelemetryFrame(_frame(lap: 3, fuel: 60));
    expect(manager.current.startFinishLapProgress, isNull);

    manager.handleHudData(hudAt(4.0));
    manager.handleTelemetryFrame(_frame(lap: 4, fuel: 58, lastLapTimeMs: 100000));
    expect(manager.current.startFinishLapProgress, 4.0);

    // A new session forgets it -- it may be elsewhere.
    manager.handleTelemetryFrame(_frame(lap: 4, fuel: 58, flags: 0));
    manager.handleTelemetryFrame(_frame(lap: 1, fuel: 100));
    expect(manager.current.startFinishLapProgress, isNull);
  });

  test('the start line is not learned while the map is not tracking us', () {
    final manager = _manager();
    manager.handleTelemetryFrame(_frame(lap: 3, fuel: 60));
    manager.handleHudData(HudOverlayData.fromMap({}));
    manager.handleTelemetryFrame(_frame(lap: 4, fuel: 58, lastLapTimeMs: 100000));
    expect(manager.current.startFinishLapProgress, isNull);
  });

  test('our own pit marker registers our stop, records the pit location, and flags the laps', () {
    final manager = _manager();
    HudOverlayData hud({required bool inPit, double progress = 300}) => HudOverlayData.fromMap({
          'playerInPit': inPit,
          'traffic': {'trackReady': true, 'playerLapProgress': progress, 'lapSeconds': 100.0, 'cars': []},
        });
    manager.handleTelemetryFrame(_frame(lap: 1, fuel: 100));
    manager.handleTelemetryFrame(_frame(lap: 2, fuel: 97, lastLapTimeMs: 90000));
    manager.handleHudData(hud(inPit: false));
    expect(manager.current.pitLapProgress, isNull);

    // The "P" shows as we enter the pit lane: not a stop until we stop.
    manager.handleHudData(hud(inPit: true, progress: 4.0));
    expect(manager.current.pitLapProgress, 4.0);
    expect(manager.pitStopTracker.pitLaps, isEmpty);
    manager.handleTelemetryFrame(_frame(lap: 2, fuel: 97, speedKmh: 0));
    manager.handleHudData(hud(inPit: true, progress: 4.0));
    expect(manager.pitStopTracker.pitLaps, {2, 3});

    // Still in the pits on the next update: not registered twice.
    manager.handleHudData(hud(inPit: true, progress: 5.0));
    expect(manager.pitStopTracker.pitLaps, {2, 3});
    expect(manager.current.pitLapProgress, 5.0);
  });

  test('a rejoin forecast is produced once the map has timed a lap', () {
    final manager = _manager();
    manager.handleHudData(HudOverlayData.fromMap({
      'traffic': {
        'trackReady': true,
        'playerLapProgress': 300.0,
        'lapSeconds': 100.0,
        'cars': [
          {'lapProgress': 50.0, 'count': 1, 'secondsBehind': 26.0},
        ],
      },
    }));
    final forecast = manager.current.rejoinForecast!;
    expect(forecast.pitLossSeconds, 25.5);
    expect(forecast.rejoinTraffic.single, closeTo(0.5, 1e-9));
    expect(manager.current.toPromptContext()['rejoinForecast'], isNotNull);
  });

  test('saved laps are restored without engaging telemetry, and only once', () async {
    final source = _manager();
    source.handleTelemetryFrame(_frame(lap: 1, fuel: 100));
    source.handleTelemetryFrame(_frame(lap: 2, fuel: 97, lastLapTimeMs: 90000));
    source.handleTelemetryFrame(_frame(lap: 3, fuel: 94, lastLapTimeMs: 91000));
    await Future<void>.delayed(Duration.zero); // let the per-lap save finish
    expect(source.current.practiceLaps, hasLength(2));

    // "App restart": a brand-new manager, telemetry never started.
    final restarted = _manager();
    final emitted = <int>[];
    restarted.stream.listen((s) => emitted.add(s.practiceLaps.length));
    await restarted.loadPersistedData();
    await Future<void>.delayed(Duration.zero); // stream events are delivered async
    expect(restarted.current.practiceLaps, hasLength(2));
    expect(emitted.last, 2, reason: 'the dashboard hears about the restored laps');

    // A new lap after the restart appends rather than replacing.
    restarted.handleTelemetryFrame(_frame(lap: 1, fuel: 100));
    restarted.handleTelemetryFrame(_frame(lap: 2, fuel: 97, lastLapTimeMs: 89000));
    expect(restarted.current.practiceLaps, hasLength(3));

    // A second load (as start() makes) doesn't reload and drop that lap.
    await restarted.loadPersistedData();
    expect(restarted.current.practiceLaps, hasLength(3));
  });

  group('the HUD tyre label', () {
    HudOverlayData hud(String label, {double? wear}) => HudOverlayData.fromMap({
          'tireCompound': label,
          if (wear != null) ...{
            'tireWearFrontLeftPercent': wear,
            'tireWearFrontRightPercent': wear,
            'tireWearRearLeftPercent': wear,
            'tireWearRearRightPercent': wear,
          },
        });

    test('sets the starting tyre once it holds -- a blip does not', () {
      final manager = _manager();
      var clock = DateTime(2026, 11, 18, 15);
      manager.now = () => clock;
      manager.handleTelemetryFrame(_frame(lap: 1, fuel: 100));
      manager.handleHudData(hud('RM'));
      clock = clock.add(const Duration(seconds: 2));
      manager.handleHudData(hud('RS')); // one misread
      clock = clock.add(const Duration(seconds: 2));
      for (var i = 0; i < 4; i++) {
        manager.handleHudData(hud('RH'));
        clock = clock.add(const Duration(seconds: 2));
      }
      expect(manager.practiceLapLogger.currentTireCompound, 'Racing Hard');
    });

    // 16 and 18 Nov: every in-lap logged as Softs on worn tyres.
    test('mid-race, a label that changes on worn tyres is a misread', () {
      final manager = _manager();
      var clock = DateTime(2026, 11, 18, 15);
      manager.now = () => clock;
      manager.setPracticeTireCompound('Racing Hard');
      manager.handleTelemetryFrame(_frame(lap: 9, fuel: 50));
      manager.handleTelemetryFrame(_frame(lap: 9, fuel: 50, flags: 0)); // pit entry, out of view
      for (var i = 0; i < 5; i++) {
        manager.handleHudData(hud('RS', wear: 74));
        clock = clock.add(const Duration(seconds: 2));
      }
      expect(manager.practiceLapLogger.currentTireCompound, 'Racing Hard');
    });

    test('at a stop, the new set read on a fresh gauge is the tyre', () {
      final manager = _manager();
      var clock = DateTime(2026, 11, 18, 15);
      manager.now = () => clock;
      manager.setPracticeTireCompound('Racing Hard');
      manager.handleTelemetryFrame(_frame(lap: 9, fuel: 50));
      manager.handleTelemetryFrame(_frame(lap: 10, fuel: 50, lastLapTimeMs: 97000, speedKmh: 0)); // in the box
      for (var i = 0; i < 5; i++) {
        manager.handleHudData(hud('IM', wear: 99));
        clock = clock.add(const Duration(seconds: 2));
      }
      expect(manager.practiceLapLogger.currentTireCompound, 'Intermediate');
    });
  });

  test("the tyre GT7 shows being fitted to our car in the pits becomes the logged tyre", () {
    final manager = _manager();
    final pitService = HudOverlayData.fromMap({
      'playerInPit': true,
      'playerPitService': {'tyre': 'S', 'fuel': 20},
    });
    manager.handleTelemetryFrame(_frame(lap: 5, fuel: 60));
    manager.handleHudData(pitService);
    expect(manager.practiceLapLogger.currentTireCompound, isNot('Racing Soft'), reason: 'moving: a misread "P"');
    manager.handleTelemetryFrame(_frame(lap: 5, fuel: 60, speedKmh: 0));
    manager.handleHudData(pitService);
    expect(manager.practiceLapLogger.currentTireCompound, isNot('Racing Soft'), reason: 'not on the car yet');
    // The new set goes on: the wear gauge jumps back up.
    HudOverlayData wear(double w) => HudOverlayData.fromMap({
          'tireWearFrontLeftPercent': w,
          'tireWearFrontRightPercent': w,
          'tireWearRearLeftPercent': w,
          'tireWearRearRightPercent': w,
        });
    manager.handleHudData(wear(40));
    for (var i = 0; i < 3; i++) {
      manager.handleHudData(wear(100));
    }
    expect(manager.practiceLapLogger.currentTireCompound, 'Racing Soft');
  });

  // AI race, 16 Nov: GT7's pit menu showed Soft at pit entry, then the
  // Hards were fitted -- the in-lap was logged on Softs.
  test('the in-lap keeps the old tyre; the tyre chosen in the pit menu starts once it is on', () {
    final manager = _manager()..setMode(AppMode.race);
    manager.setPracticeTireCompound('Intermediate');
    HudOverlayData hud({double? wear, String? menu}) => HudOverlayData.fromMap({
          if (wear != null) ...{
            'tireWearFrontLeftPercent': wear,
            'tireWearFrontRightPercent': wear,
            'tireWearRearLeftPercent': wear,
            'tireWearRearRightPercent': wear,
          },
          'playerInPit': menu != null,
          if (menu != null) 'playerPitService': {'tyre': menu, 'fuel': 40},
        });
    var fuel = 100.0;
    manager.handleTelemetryFrame(_frame(lap: 1, fuel: fuel));
    for (var lap = 2; lap <= 10; lap++) {
      fuel -= 4;
      manager.handleTelemetryFrame(_frame(lap: lap, fuel: fuel, lastLapTimeMs: 100000));
      manager.handleHudData(hud(wear: 100.0 - lap * 2));
    }
    // Pit entry at the end of lap 10: out of view, the menu shows Soft.
    manager.handleTelemetryFrame(_frame(lap: 10, fuel: fuel, flags: 0));
    manager.handleHudData(hud(menu: 'S'));
    manager.handleTelemetryFrame(_frame(lap: 11, fuel: fuel, lastLapTimeMs: 97000, speedKmh: 60));
    // The box on lap 11: Hards chosen, fuel in, new tyres read on the way out.
    manager.handleTelemetryFrame(_frame(lap: 11, fuel: fuel, speedKmh: 0));
    manager.handleHudData(hud(menu: 'H'));
    manager.handleTelemetryFrame(_frame(lap: 11, fuel: fuel + 30, speedKmh: 0));
    for (var i = 0; i < 4; i++) {
      manager.handleHudData(hud(wear: 100));
    }
    manager.handleTelemetryFrame(_frame(lap: 12, fuel: fuel + 26, lastLapTimeMs: 125000));
    final laps = manager.practiceLapLogger.laps;
    expect(laps[laps.length - 2].tireCompound, 'Intermediate', reason: 'lap 10, the in-lap');
    expect(laps.last.tireCompound, 'Racing Hard', reason: 'lap 11, the stop');
  });

  // Round 5 at the Nürburgring on 16 Nov: one race, logged as 7 races and
  // a "pit stop" nearly every lap.
  test('a pit stop where GT7 drops the car out of view stays one race, one stint per set of tyres', () async {
    final manager = _manager()..setMode(AppMode.race);
    var clock = DateTime(2026, 11, 16, 15);
    manager.now = () => clock;
    var sessionsEnded = 0;
    manager.sessionEnded.listen((_) => sessionsEnded++);
    HudOverlayData hud({double wear = 80, bool inPit = false}) => HudOverlayData.fromMap({
          'tireWearFrontLeftPercent': wear,
          'tireWearFrontRightPercent': wear,
          'tireWearRearLeftPercent': wear,
          'tireWearRearRightPercent': wear,
          'playerInPit': inPit,
        });

    var fuel = 100.0;
    manager.handleTelemetryFrame(_frame(lap: 1, fuel: fuel));
    for (var lap = 2; lap <= 6; lap++) {
      fuel -= 4;
      manager.handleTelemetryFrame(_frame(lap: lap, fuel: fuel, lastLapTimeMs: 98000));
      // Misreads mid-stint: a low wear reading, then normal ones; a "P".
      manager.handleHudData(hud(wear: 40));
      for (var i = 0; i < 4; i++) {
        manager.handleHudData(hud(wear: 90.0 - lap));
      }
      manager.handleHudData(hud(wear: 90.0 - lap, inPit: true));
    }
    expect(manager.pitStopTracker.pitLaps, isEmpty, reason: 'no stop without stopping');

    // Pit on lap 6: the cutscene takes the car out of view for 40s,
    // refuelled and on fresh tyres.
    for (var s = 0; s < 40; s++) {
      clock = clock.add(const Duration(seconds: 1));
      manager.handleTelemetryFrame(_frame(lap: 6, fuel: fuel, flags: TelemetryFlags.carOnTrack | TelemetryFlags.loadingOrProcessing));
    }
    fuel = 60;
    manager.handleTelemetryFrame(_frame(lap: 6, fuel: fuel, speedKmh: 40));
    for (var i = 0; i < 4; i++) {
      manager.handleHudData(hud(wear: 100));
    }
    manager.handleTelemetryFrame(_frame(lap: 7, fuel: fuel - 1, lastLapTimeMs: 125000));
    manager.handleTelemetryFrame(_frame(lap: 8, fuel: fuel - 5, lastLapTimeMs: 97000));
    await Future<void>.delayed(Duration.zero);

    expect(sessionsEnded, 0);
    final laps = manager.current.practiceLaps;
    expect(laps.map((l) => l.raceNumber).toSet(), {1});
    expect(laps.map((l) => l.stintNumber).toSet(), hasLength(2));
    expect(manager.pitStopTracker.stopCount, 1);
    expect(laps.where((l) => l.isPitLap), hasLength(2));
  });

  test('NEW RACE: the next lap starts a new race, with fuel tracking starting over', () async {
    final manager = _manager()..setMode(AppMode.race);
    var sessionsEnded = 0;
    manager.sessionEnded.listen((_) => sessionsEnded++);
    expect(manager.practiceLapLogger.upcomingRaceNumber, 1);
    manager.handleTelemetryFrame(_frame(lap: 1, fuel: 100));
    manager.handleTelemetryFrame(_frame(lap: 2, fuel: 97, lastLapTimeMs: 90000));
    manager.handleTelemetryFrame(_frame(lap: 3, fuel: 94, lastLapTimeMs: 90000));
    expect(manager.practiceLapLogger.upcomingRaceNumber, 1);
    expect(manager.current.fuelPrediction.hasEnoughData, isTrue);

    // A restart during lap 1: the lap counter never goes back past where it was.
    manager.startNewRace();
    await Future<void>.delayed(Duration.zero);
    expect(sessionsEnded, 1);
    expect(manager.practiceLapLogger.upcomingRaceNumber, 2);
    manager.handleTelemetryFrame(_frame(lap: 1, fuel: 100));
    manager.handleTelemetryFrame(_frame(lap: 2, fuel: 97, lastLapTimeMs: 91000));
    expect(manager.current.practiceLaps.map((l) => l.raceNumber), [1, 1, 2]);
  });
}
