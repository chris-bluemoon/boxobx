import 'dart:async';

import '../models/weather_forecast.dart';
import '../models/fused_race_state.dart';
import '../models/telemetry_frame.dart';
import '../models/hud_overlay_data.dart';
import '../models/connection_status.dart';
import '../models/fuel_prediction.dart';
import '../models/tire_wear_estimate.dart';
import 'telemetry_udp_service.dart';
import 'hud_ocr_service.dart';
import 'corner_report.dart';
import 'race_lap_estimator.dart';
import 'sector_calculator.dart';
import 'fuel_predictor.dart';
import 'crash_detector.dart';
import 'race_rival_tracker.dart';
import 'tire_wear_tracker.dart';
import 'practice_lap_logger.dart';
import 'water_trend.dart';
import 'practice_log_store.dart';
import 'shift_history_tracker.dart';
import 'pit_stop_tracker.dart';
import 'pit_lane_monitor.dart';
import 'rejoin_forecaster.dart';
import '../models/app_mode.dart';
import 'time_trial_logger.dart';
import 'time_trial_store.dart';
import '../models/opponent_pit_stop.dart';
import '../models/power_band_config.dart';
import '../models/practice_lap_record.dart';

/// Component C: Fused Race State Manager.
///
/// Continuously fuses the Telemetry Network Worker stream and the HUD
/// Screen Parser stream, runs incoming telemetry through the Sector
/// Calculator, and exposes a single master [FusedRaceState] stream to the
/// rest of the app (UI + Voice Engine).
class FusedRaceStateManager {
  final TelemetryUdpService telemetryService;
  final HudOcrService hudService;

  /// A timed race's lap count (see RaceLapEstimator).
  final RaceLapEstimator raceLapEstimator = RaceLapEstimator();

  final SectorCalculator sectorCalculator;
  final FuelPredictor fuelPredictor;
  final TireWearTracker tireWearTracker;
  final PracticeLapLogger practiceLapLogger;

  /// Which way the water gauge is going (see WaterTrend).
  final waterTrend = WaterTrend();
  final ShiftHistoryTracker shiftHistoryTracker;
  final PitStopTracker pitStopTracker;
  final PitLaneMonitor pitLaneMonitor;

  final _opponentPittedController = StreamController<List<OpponentPitStop>>.broadcast();

  /// Fires with pit stops ready to announce (see PitLaneMonitor) --
  /// the dashboard has Boxington call these out. The full log, kept
  /// up to date with tyre/fuel, is FusedRaceState.opponentPitStops.
  Stream<List<OpponentPitStop>> get opponentPitted => _opponentPittedController.stream;

  /// Serious crashes (see CrashDetector).
  final CrashDetector crashDetector = CrashDetector();
  final _crashController = StreamController<Crash>.broadcast();

  /// Fires once per serious crash -- the dashboard has Boxington react
  /// to it (Race Mode only).
  Stream<Crash> get crashes => _crashController.stream;

  /// The chosen race rival (see RaceRivalTracker) -- Race Mode calls.
  final RaceRivalTracker raceRivalTracker = RaceRivalTracker();
  final _rivalEventController = StreamController<RivalEvent>.broadcast();

  /// Fires with each call to make about the race rival.
  Stream<RivalEvent> get rivalEvents => _rivalEventController.stream;

  /// Chooses the race rival (null = none).
  void setRaceRival(String? name) {
    raceRivalTracker.setRival(name);
    _state = _state.copyWith(clearRaceRival: true);
    _controller.add(_state);
  }

  final _sessionEndedController = StreamController<void>.broadcast();

  /// Fires when the driver leaves the track (race finished/exited,
  /// loading into another session). Per-lap predictors are already
  /// reset here; listeners reset their own per-session state (rival
  /// tracking, queued callouts...).
  Stream<void> get sessionEnded => _sessionEndedController.stream;

  /// GT7's status flags are only trusted once a frame has reported
  /// "car on track". Until then every frame is treated as driving --
  /// the pre-flags behaviour -- so if the flag offset were ever wrong
  /// for a game version, logging degrades to how it worked before
  /// rather than silently stopping altogether.
  bool _flagsTrusted = false;
  bool _wasOnTrack = false;
  int? _activeCarCode;
  int? _lastLapForStartLine;
  bool _playerWasInPit = false;

  /// The pit stop time entered for the current round (GT7's on-screen
  /// "Pit Stop Time", whole stop including service -- see
  /// RaceBriefing.pitStopTimeSeconds); null = not entered, so the rejoin
  /// forecast uses its default.
  double? _pitStopTimeSeconds;

  /// Records laps in Time Trialing mode (see AppMode.timeTrial).
  final TimeTrialLogger timeTrialLogger = TimeTrialLogger();

  final _controller = StreamController<FusedRaceState>.broadcast();
  FusedRaceState _state = FusedRaceState.initial();

  StreamSubscription<TelemetryFrame>? _telemetrySub;
  StreamSubscription<HudOverlayData>? _hudSub;

  FusedRaceStateManager({
    required this.telemetryService,
    required this.hudService,
    required this.sectorCalculator,
    required this.fuelPredictor,
    TireWearTracker? tireWearTracker,
    PracticeLapLogger? practiceLapLogger,
    ShiftHistoryTracker? shiftHistoryTracker,
    PitStopTracker? pitStopTracker,
    PitLaneMonitor? pitLaneMonitor,
  }) : tireWearTracker = tireWearTracker ?? TireWearTracker(),
       practiceLapLogger = practiceLapLogger ?? PracticeLapLogger(),
       shiftHistoryTracker = shiftHistoryTracker ?? ShiftHistoryTracker(),
       pitStopTracker = pitStopTracker ?? PitStopTracker(),
       pitLaneMonitor = pitLaneMonitor ?? PitLaneMonitor();

  Stream<FusedRaceState> get stream => _controller.stream;
  FusedRaceState get current => _state;

  Stream<ConnectionStatus> get telemetryStatusStream => telemetryService.statusStream;
  Stream<ConnectionStatus> get hudStatusStream => hudService.statusStream;
  ConnectionStatus get telemetryStatus => telemetryService.status;
  ConnectionStatus get hudStatus => hudService.status;

  Future<void>? _persistedDataLoad;

  /// Practice-log writes, run strictly one after another. Saves aren't
  /// awaited by the telemetry handler, and two in flight could finish
  /// out of order -- observed: the first save of a session completing
  /// AFTER the next one, leaving the stored log a lap short.
  Future<void> _lapWrites = Future.value();

  /// Time-trial writes, queued the same way.
  Future<void> _timeTrialWrites = Future.value();

  /// Queues a time-trial save for the round current now (null until
  /// the dashboard has said which round it is: the store then uses the
  /// saved one).
  Future<void> _persistTimeTrial(Future<void> Function(String? round) write) {
    final round = _roundKnown ? (_round ?? '') : null;
    return _timeTrialWrites = _timeTrialWrites.then((_) => write(round)).catchError((Object _) {});
  }

  /// Queues a save of the practice laps as they are now, for the round
  /// current now -- see [_persistTimeTrial].
  Future<void> _persistLaps(Future<void> Function(List<PracticeLapRecord> laps, String? round) write) {
    final snapshot = practiceLapLogger.laps;
    final round = _roundKnown ? (_round ?? '') : null;
    return _lapWrites = _lapWrites.then((_) => write(snapshot, round)).catchError((Object _) {});
  }

  /// Restores the practice laps saved for the current round (see
  /// PracticeLogStore). Call when
  /// the app opens, so the lap count and practice log are right without
  /// connecting to the console first -- it used to happen only on
  /// ENGAGE TELEMETRY, so every launch showed 0 laps until then. Runs
  /// once; later calls (start() makes one) wait for the same load.
  Future<void> loadPersistedData() => _persistedDataLoad ??= _loadPersistedData();

  Future<void> _loadPersistedData() async {
    final timeTrialLaps = await TimeTrialStore.load();
    if (timeTrialLaps.isNotEmpty) {
      timeTrialLogger.seed(timeTrialLaps);
      _state = _state.copyWith(timeTrialLaps: timeTrialLogger.laps);
    }

    final persistedLaps = await PracticeLogStore.load();
    if (persistedLaps.isNotEmpty) {
      practiceLapLogger.seedWithPersistedLaps(persistedLaps);
      _state = _state.copyWith(practiceLaps: practiceLapLogger.laps);
      _controller.add(_state);
    }
  }

  Future<void> start(String consoleIp) async {
    await sectorCalculator.loadSectorMaps();
    await loadPersistedData();

    _telemetrySub = telemetryService.stream.listen(handleTelemetryFrame);

    _hudSub = hudService.stream.listen(handleHudData);

    await telemetryService.start(consoleIp);
    await hudService.start();
  }

  /// Processes one telemetry frame. Public so the session/pit logic can
  /// be tested without sockets; in the app it's fed by [start].
  void handleTelemetryFrame(TelemetryFrame frame) {
    if (frame.isCarOnTrack) _flagsTrusted = true;
    final onTrack = !_flagsTrusted || (frame.isCarOnTrack && !frame.isLoading);
    final driving = !_flagsTrusted || frame.isDriving;

    if (_wasOnTrack && !onTrack) _endSession();
    _wasOnTrack = onTrack;

    if (!onTrack) {
      // In menus GT7 keeps streaming the last values, frozen. Show a
      // blank frame instead (once -- not 60 times a second).
      if (_state.sessionPhase != SessionPhase.offTrack) {
        _state = _state.copyWith(telemetry: TelemetryFrame.empty(), sessionPhase: SessionPhase.offTrack);
        _controller.add(_state);
      }
      return;
    }

    if (!driving) {
      // Paused: keep showing the frozen values, but don't feed them to
      // anything that accumulates per-lap data.
      _state = _state.copyWith(telemetry: frame, sessionPhase: SessionPhase.paused);
      _controller.add(_state);
      crashDetector.reset();
      return;
    }

    _updateActiveCar(frame);
    _learnStartFinishLine(frame);
    _applyPitStopUpdate(pitStopTracker.update(frame));

    sectorCalculator.recordsReference = _state.mode.logsTimeTrialLaps;
    final sectorState = sectorCalculator.evaluate(frame);
    final fuelPrediction = fuelPredictor.update(frame);
    final tireWearEstimate = tireWearTracker.update(frame);
    final lapCountBefore = practiceLapLogger.laps.length;
    // Time Trialing keeps its laps apart from the stints (a low-fuel
    // qualifying lap would skew fuel and wear figures).
    final raceLaps = raceLapEstimator.update(frame, pitLaps: pitStopTracker.pitLaps);
    final lapSectors = sectorState.justCompletedSectorsMs;
    if (sectorState.lapJustCompleted) _updateCornerReport();
    practiceLapLogger.completedLapSectorsMs = lapSectors;
    if (_state.mode.logsStintLaps) practiceLapLogger.update(frame);
    if (_state.mode.logsTimeTrialLaps &&
        timeTrialLogger.update(frame, tireCompound: practiceLapLogger.currentTireCompound, sectorsMs: lapSectors)) {
      _state = _state.copyWith(timeTrialLaps: timeTrialLogger.laps);
      final snapshot = timeTrialLogger.laps;
      _persistTimeTrial((round) => TimeTrialStore.save(snapshot, round: round));
    }
    shiftHistoryTracker.update(frame);
    final crash = crashDetector.update(frame);
    if (crash != null) _crashController.add(crash);
    _state = _state.copyWith(
      telemetry: frame,
      sectors: sectorState,
      fuelPrediction: fuelPrediction,
      tireWearEstimate: tireWearEstimate,
      recentShifts: shiftHistoryTracker.recentShifts,
      practiceLaps: practiceLapLogger.laps,
      sessionPhase: _flagsTrusted ? SessionPhase.driving : SessionPhase.unknown,
      raceLaps: raceLaps,
      clearRaceLaps: raceLaps == null,
    );
    _controller.add(_state);

    // Persist as soon as a new lap is logged (rather than on some
    // timer) so a crash/forced-quit mid-session loses at most the
    // CURRENT in-progress lap, never a previously completed one.
    if (practiceLapLogger.laps.length > lapCountBefore) {
      _persistLaps((laps, round) => PracticeLogStore.save(laps, round: round));
    }
  }

  /// Processes one HUD OCR update -- see [handleTelemetryFrame].
  void handleHudData(HudOverlayData hud) {
    // Keeps PracticeLapLogger's auto-attached tire-wear reading
    // current so it reflects whatever the OCR relay most recently
    // read at the moment a lap actually completes, the same way
    // setPracticeTireCompound keeps currentTireCompound current from
    // the dashboard's manual picker -- see
    // PracticeLapLogger.currentTireWearPercent.
    final wearReadings = [
      hud.tireWearFrontLeftPercent,
      hud.tireWearFrontRightPercent,
      hud.tireWearRearLeftPercent,
      hud.tireWearRearRightPercent,
    ].whereType<double>();
    if (wearReadings.isNotEmpty) {
      final averageWear = wearReadings.reduce((a, b) => a + b) / wearReadings.length;
      practiceLapLogger.currentTireWearPercent = averageWear;
      _applyPitStopUpdate(pitStopTracker.reportTireWear(averageWear));
    }

    if (hud.gridPosition > 0) practiceLapLogger.currentPosition = hud.gridPosition;
    if (hud.waterPercent case final water?) {
      practiceLapLogger.reportWater(water);
      waterTrend.add(water, DateTime.now());
      _state = _state.copyWith(waterPercentPerMinute: waterTrend.percentPerMinute, clearWaterTrend: waterTrend.percentPerMinute == null);
    }

    if (hud.playerInPit) {
      if (!_playerWasInPit) _applyPitStopUpdate(pitStopTracker.reportPlayerInPit());
      // The compound GT7 shows being fitted to our car is the tyre for
      // the stint that follows.
      final fitted = _compoundForPitTyre(hud.playerPitService?.tyre);
      if (fitted != null) practiceLapLogger.currentTireCompound = fitted;
      final progress = hud.traffic.playerLapProgress;
      if (hud.traffic.trackReady && progress != null) _state = _state.copyWith(pitLapProgress: progress);
    }
    _playerWasInPit = hud.playerInPit;

    final pitted = pitLaneMonitor.check(hud.driversInPit, ourLap: _state.telemetry.currentLap);
    final rivalEvents = raceRivalTracker.update(
      hud,
      ourLap: _state.telemetry.currentLap,
      ourLastLapMs: _state.telemetry.lastLapTimeMs,
      pitLapProgress: _state.pitLapProgress,
      now: DateTime.now(),
    );
    _state = _state.copyWith(
      raceRival: raceRivalTracker.state,
      hud: hud,
      opponentPitStops: hud.driversInPit.isEmpty && pitted.isEmpty ? null : pitLaneMonitor.stops,
      rejoinForecast: RejoinForecaster.forecast(hud.traffic, measuredPitLossSeconds: _pitStopTimeSeconds),
    );
    _controller.add(_state);
    if (pitted.isNotEmpty) _opponentPittedController.add(pitted);
    rivalEvents.forEach(_rivalEventController.add);
  }

  /// GT7's pit-stop tyre letter (see the relay's read_pit_service) to the
  /// compound name laps are logged with.
  static String? _compoundForPitTyre(String? letter) => switch (letter) {
    'S' => 'Racing Soft',
    'M' => 'Racing Medium',
    'H' => 'Racing Hard',
    'IM' => 'Intermediate',
    'W' => 'Heavy Wet',
    _ => null,
  };

  /// The lap counter ticks over exactly as we cross the start/finish
  /// line, so wherever the course map has our marker at that moment IS
  /// the line. The relay updates about once a second, so this can be
  /// slightly behind the true line; good enough for traffic around the
  /// pits (see FusedRaceState.startFinishLapProgress).
  void _learnStartFinishLine(TelemetryFrame frame) {
    final last = _lastLapForStartLine;
    _lastLapForStartLine = frame.currentLap;
    if (last == null || frame.currentLap != last + 1) return;
    final traffic = _state.hud.traffic;
    final progress = traffic.playerLapProgress;
    if (!traffic.trackReady || progress == null) return;
    _state = _state.copyWith(startFinishLapProgress: progress);
  }

  /// Picks the shift window for whichever car GT7 says is being driven.
  void _updateActiveCar(TelemetryFrame frame) {
    if (frame.carCode == 0 || frame.carCode == _activeCarCode) return;
    _activeCarCode = frame.carCode;
    final config = PowerBandConfig.forCar(
      frame.carCode,
      minAlertRpm: frame.minAlertRpm,
      maxAlertRpm: frame.maxAlertRpm,
    );
    shiftHistoryTracker.config = config;
    practiceLapLogger.powerBandConfig = config;
    _state = _state.copyWith(powerBand: config);
  }

  void _applyPitStopUpdate(PitStopUpdate? update) {
    if (update == null) return;

    final stopLap = update.stopDetectedOnLap;
    if (stopLap != null) {
      final pitLaps = {stopLap, stopLap + 1};
      tireWearTracker.excludeLaps(pitLaps);
      practiceLapLogger.markPitLaps(pitLaps);
      // New tyres and/or fuel: what follows is a new stint.
      practiceLapLogger.startNewStint(automatic: true);
    }

    if (update.tiresChanged) {
      // New stint: degradation is measured against the fresh set only.
      tireWearTracker
        ..reset()
        ..excludeLaps(pitStopTracker.pitLaps);
      _state = _state.copyWith(tireWearEstimate: TireWearEstimate.insufficientData());
    }
    _controller.add(_state);
  }

  /// The driver left the track: everything measured per session starts
  /// over. Recorded practice laps are kept.
  void _endSession() {
    fuelPredictor.reset();
    tireWearTracker.reset();
    shiftHistoryTracker.reset();
    pitStopTracker.reset();
    pitLaneMonitor.reset();
    crashDetector.reset();
    raceRivalTracker.reset();
    practiceLapLogger.startNewSession();
    timeTrialLogger.startNewSession();
    sectorCalculator.reset();
    raceLapEstimator.reset();
    _lastLapForStartLine = null;
    _state = _state.copyWith(
      // The next session may be on a different circuit.
      clearStartFinishLapProgress: true,
      opponentPitStops: const [],
      fuelPrediction: FuelPrediction.insufficientData(),
      tireWearEstimate: TireWearEstimate.insufficientData(),
      recentShifts: const [],
      clearRaceRival: true,
    );
    _controller.add(_state);
    _sessionEndedController.add(null);
  }

  /// Deletes one time-trial lap (e.g. one with a track-limits violation).
  Future<void> removeTimeTrialLap(DateTime recordedAt) async {
    timeTrialLogger.remove(recordedAt);
    _state = _state.copyWith(timeTrialLaps: timeTrialLogger.laps);
    _controller.add(_state);
    final snapshot = timeTrialLogger.laps;
    await _persistTimeTrial((round) => TimeTrialStore.save(snapshot, round: round));
  }

  Future<void> clearTimeTrialLaps() async {
    timeTrialLogger.clear();
    _state = _state.copyWith(timeTrialLaps: const []);
    _controller.add(_state);
    await _persistTimeTrial((round) => TimeTrialStore.clear(round: round));
  }

  /// The current round's pit stop time as entered on the strategy screen
  /// (null = not entered) -- used for the rejoin forecast and pit calls.
  void setPitStopTime(double? seconds) {
    _pitStopTimeSeconds = seconds;
    _state = _state.copyWith(pitStopTimeSeconds: seconds, clearPitStopTime: seconds == null);
  }

  /// The current round's weather slots (null = none in its briefing).
  void setWeather(WeatherForecast? weather) {
    _state = _state.copyWith(weather: weather, clearWeather: weather == null);
    _controller.add(_state);
  }

  /// Compares the lap just completed with the reference it was driven
  /// against, corner by corner (see CornerReport).
  void _updateCornerReport() {
    final lap = sectorCalculator.lastLapTrace;
    final reference = sectorCalculator.lastLapComparedTo;
    if (lap == null || reference == null) return;
    final report = CornerReport.compare(lap, reference, sectorCalculator.corners);
    if (report != null) _state = _state.copyWith(cornerReport: report);
  }

  /// The round's time limit (null for a lap race) and the strategy's
  /// lap count -- a timed race's laps are estimated from them and the
  /// pace (see RaceLapEstimator).
  void setRaceLength({int? minutes, int? plannedLaps}) => raceLapEstimator
    ..raceLengthMinutes = minutes
    ..plannedLaps = plannedLaps;

  /// The round now saved on the strategy screen -- the live delta's
  /// reference lap belongs to a round (see SectorCalculator.round).
  ///
  /// The lap logs are kept per round (see PracticeLogStore), so when the
  /// round changes after the app has loaded, the new round's laps are
  /// loaded in place of the old one's.
  void setRound(String? name) {
    sectorCalculator.round = name;
    final changed = _roundKnown && name != _round;
    _round = name;
    _roundKnown = true;
    if (changed) reloadRoundLaps();
  }

  String? _round;
  bool _roundKnown = false;

  /// Replaces the laps in memory with the current round's saved ones,
  /// once any saves still in flight have landed.
  Future<void> reloadRoundLaps() async {
    await _lapWrites;
    await _timeTrialWrites;
    final practice = await PracticeLogStore.load();
    final timeTrial = await TimeTrialStore.load();
    practiceLapLogger.seedWithPersistedLaps(practice);
    timeTrialLogger.seed(timeTrial);
    _state = _state.copyWith(practiceLaps: practiceLapLogger.laps, timeTrialLaps: timeTrialLogger.laps);
    _controller.add(_state);
  }

  /// Practice or race -- see AppMode. Recording is the same in both.
  void setMode(AppMode mode) {
    practiceLapLogger.isRaceMode = mode == AppMode.race;
    _state = _state.copyWith(mode: mode);
    _controller.add(_state);
  }

  /// The dashboard's NEW STINT button: laps from now on count as a new
  /// stint (e.g. you reset tyres/fuel in the garage without a pit stop
  /// the app could see).
  void startNewStint() {
    practiceLapLogger.startNewStint();
    _controller.add(_state);
  }

  /// The running test has reached its target (Boxington has called it):
  /// closes off its data and ends it -- see
  /// PracticeLapLogger.completeActiveTest.
  Future<void> completeActiveTest() async {
    if (!practiceLapLogger.completeActiveTest()) return;
    _state = _state.copyWith(practiceLaps: practiceLapLogger.laps);
    _controller.add(_state);
    await _persistLaps((laps, round) => PracticeLogStore.save(laps, round: round));
  }

  /// The driver is starting planned test [testNumber] (see TestPlan):
  /// laps from now on are a new stint, counted towards that test.
  void startTestStint(int testNumber) {
    practiceLapLogger.startNewStint(testNumber: testNumber);
    _controller.add(_state);
  }

  Future<void> stop() async {
    await telemetryService.stop();
    await hudService.stop();
    await _telemetrySub?.cancel();
    await _hudSub?.cancel();
  }

  /// Which tire compound to attribute to practice laps completed from
  /// now on -- call this whenever the driver changes the dashboard's
  /// tire picker (GT7's telemetry has no tire-compound field at all,
  /// so this manual selection is the only source of truth for it).
  void setPracticeTireCompound(String compound) {
    practiceLapLogger.currentTireCompound = compound;
  }

  /// Clears the current round's practice lap log (both in memory and
  /// saved) -- an explicit driver action. Other rounds' laps are kept.
  Future<void> clearPracticeLaps() async {
    practiceLapLogger.reset();
    await _persistLaps((_, round) => PracticeLogStore.clear(round: round));
    _state = _state.copyWith(practiceLaps: const []);
    _controller.add(_state);
  }

  /// Deletes a single logged practice lap (identified by its
  /// recordedAt timestamp) and persists the renumbered remainder --
  /// lets the driver remove one bad/outlier lap (a spin, a lap broken
  /// up by traffic) without wiping the whole practice log.
  Future<void> removePracticeLap(DateTime recordedAt) async {
    practiceLapLogger.removeLap(recordedAt);
    await _persistLaps((laps, round) => PracticeLogStore.save(laps, round: round));
    _state = _state.copyWith(practiceLaps: practiceLapLogger.laps);
    _controller.add(_state);
  }

  /// Deletes every lap of one stint (identified by their recordedAt
  /// timestamps) and persists the rest.
  Future<void> removePracticeLaps(Set<DateTime> recordedAts) async {
    practiceLapLogger.removeLaps(recordedAts);
    await _persistLaps((laps, round) => PracticeLogStore.save(laps, round: round));
    _state = _state.copyWith(practiceLaps: practiceLapLogger.laps);
    _controller.add(_state);
  }

  void dispose() {
    stop();
    _controller.close();
    _sessionEndedController.close();
    _opponentPittedController.close();
    _crashController.close();
    _rivalEventController.close();
  }
}
