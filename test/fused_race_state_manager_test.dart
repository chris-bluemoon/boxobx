// Drives FusedRaceStateManager's frame handling directly (no sockets)
// to cover how GT7's status flags, car ID and pit detection flow into
// the fused state.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  test('paused frames are shown but not counted', () {
    final manager = _manager();
    manager.handleTelemetryFrame(_frame(lap: 1, fuel: 100));
    manager.handleTelemetryFrame(_frame(lap: 2, fuel: 97, lastLapTimeMs: 90000, flags: _onTrack | TelemetryFlags.paused));

    expect(manager.current.sessionPhase, SessionPhase.paused);
    expect(manager.current.telemetry.currentLap, 2);
    expect(manager.current.practiceLaps, isEmpty);
  });

  test('leaving the track ends the session: predictors reset, laps kept, display blanked', () async {
    final manager = _manager();
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

    // Leaving the track forgets it -- the next session may be elsewhere.
    manager.handleTelemetryFrame(_frame(lap: 4, fuel: 58, flags: 0));
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

    manager.handleHudData(hud(inPit: true, progress: 4.0));
    expect(manager.current.pitLapProgress, 4.0);
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
}
