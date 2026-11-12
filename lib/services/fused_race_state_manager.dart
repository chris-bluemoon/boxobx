import 'dart:async';

import '../models/fused_race_state.dart';
import '../models/telemetry_frame.dart';
import '../models/hud_overlay_data.dart';
import '../models/connection_status.dart';
import '../models/fuel_prediction.dart';
import '../models/tire_wear_estimate.dart';
import 'telemetry_udp_service.dart';
import 'hud_ocr_service.dart';
import 'sector_calculator.dart';
import 'fuel_predictor.dart';
import 'tire_wear_tracker.dart';
import 'practice_lap_logger.dart';
import 'practice_log_store.dart';
import 'shift_history_tracker.dart';

/// Component C: Fused Race State Manager.
///
/// Continuously fuses the Telemetry Network Worker stream and the HUD
/// Screen Parser stream, runs incoming telemetry through the Sector
/// Calculator, and exposes a single master [FusedRaceState] stream to the
/// rest of the app (UI + Voice Engine).
class FusedRaceStateManager {
  final TelemetryUdpService telemetryService;
  final HudOcrService hudService;
  final SectorCalculator sectorCalculator;
  final FuelPredictor fuelPredictor;
  final TireWearTracker tireWearTracker;
  final PracticeLapLogger practiceLapLogger;
  final ShiftHistoryTracker shiftHistoryTracker;

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
  })  : tireWearTracker = tireWearTracker ?? TireWearTracker(),
        practiceLapLogger = practiceLapLogger ?? PracticeLapLogger(),
        shiftHistoryTracker = shiftHistoryTracker ?? ShiftHistoryTracker();

  Stream<FusedRaceState> get stream => _controller.stream;
  FusedRaceState get current => _state;

  Stream<ConnectionStatus> get telemetryStatusStream => telemetryService.statusStream;
  Stream<ConnectionStatus> get hudStatusStream => hudService.statusStream;
  ConnectionStatus get telemetryStatus => telemetryService.status;
  ConnectionStatus get hudStatus => hudService.status;

  Future<void> start(String consoleIp) async {
    await sectorCalculator.loadTrackDatabase();

    // Restore any practice laps already logged for the current round
    // (see PracticeLogStore) -- answers "is the data stored
    // indefinitely": yes, this is what makes it survive an app
    // restart rather than starting back at zero laps every launch.
    final persistedLaps = await PracticeLogStore.load();
    if (persistedLaps.isNotEmpty) {
      practiceLapLogger.seedWithPersistedLaps(persistedLaps);
      _state = _state.copyWith(practiceLaps: practiceLapLogger.laps);
      _controller.add(_state);
    }

    _telemetrySub = telemetryService.stream.listen((frame) {
      final sectorState = sectorCalculator.evaluate(frame);
      final fuelPrediction = fuelPredictor.update(frame);
      final tireWearEstimate = tireWearTracker.update(frame);
      final lapCountBefore = practiceLapLogger.laps.length;
      practiceLapLogger.update(frame);
      shiftHistoryTracker.update(frame);
      _state = _state.copyWith(
        telemetry: frame,
        sectors: sectorState,
        fuelPrediction: fuelPrediction,
        tireWearEstimate: tireWearEstimate,
        recentShifts: shiftHistoryTracker.recentShifts,
        practiceLaps: practiceLapLogger.laps,
      );
      _controller.add(_state);

      // Persist as soon as a new lap is logged (rather than on some
      // timer) so a crash/forced-quit mid-session loses at most the
      // CURRENT in-progress lap, never a previously completed one.
      if (practiceLapLogger.laps.length > lapCountBefore) {
        PracticeLogStore.save(practiceLapLogger.laps);
      }
    });

    _hudSub = hudService.stream.listen((hud) {
      _state = _state.copyWith(hud: hud);
      _controller.add(_state);
    });

    await telemetryService.start(consoleIp);
    await hudService.start();
  }

  Future<void> stop() async {
    await telemetryService.stop();
    await hudService.stop();
    await _telemetrySub?.cancel();
    await _hudSub?.cancel();
  }

  /// Clears the FuelPredictor's lap-consumption history, so a stale
  /// prediction from a previous session doesn't linger after a manual
  /// telemetry display reset (see DashboardScreen._resetTelemetryDisplay).
  void resetFuelPrediction() {
    fuelPredictor.reset();
    _state = _state.copyWith(fuelPrediction: FuelPrediction.insufficientData());
    _controller.add(_state);
  }

  /// Clears the TireWearTracker's lap-time-degradation history -- call
  /// this when a real tire change happens (new stint) as well as
  /// alongside a manual telemetry display reset, so degradation data
  /// from the OLD set of tires doesn't contaminate the new stint's
  /// baseline.
  void resetTireWearEstimate() {
    tireWearTracker.reset();
    _state = _state.copyWith(tireWearEstimate: TireWearEstimate.insufficientData());
    _controller.add(_state);
  }

  /// Clears the ShiftHistoryTracker's recorded upshifts, so a stale
  /// shift-habit pattern from a previous session doesn't linger after a
  /// manual telemetry display reset.
  void resetShiftHistory() {
    shiftHistoryTracker.reset();
    _state = _state.copyWith(recentShifts: const []);
    _controller.add(_state);
  }

  /// Which tire compound to attribute to practice laps completed from
  /// now on -- call this whenever the driver changes the dashboard's
  /// tire picker (GT7's telemetry has no tire-compound field at all,
  /// so this manual selection is the only source of truth for it).
  void setPracticeTireCompound(String compound) {
    practiceLapLogger.currentTireCompound = compound;
  }

  /// Turns practice-lap logging on/off -- when off, laps driven are
  /// true FREE PRACTICE: nothing is recorded, persisted, or tagged to
  /// whichever round is currently saved. This is the answer to "can I
  /// practice without it counting toward a round": yes, flip this off
  /// first. Does not touch already-recorded laps either way.
  void setPracticeLoggingEnabled(bool enabled) {
    practiceLapLogger.setLoggingEnabled(enabled);
    _state = _state.copyWith(practiceLoggingEnabled: enabled);
    _controller.add(_state);
  }

  /// Clears the practice lap log entirely (both in-memory and
  /// persisted) -- an explicit driver action, separate from the
  /// automatic clearing that happens when SavedBriefingStore.save() is
  /// called under a genuinely new round name.
  Future<void> clearPracticeLaps() async {
    practiceLapLogger.reset();
    await PracticeLogStore.clear();
    _state = _state.copyWith(practiceLaps: const []);
    _controller.add(_state);
  }

  /// Deletes a single logged practice lap (identified by its
  /// recordedAt timestamp) and persists the renumbered remainder --
  /// lets the driver remove one bad/outlier lap (a spin, a lap broken
  /// up by traffic) without wiping the whole practice log.
  Future<void> removePracticeLap(DateTime recordedAt) async {
    practiceLapLogger.removeLap(recordedAt);
    await PracticeLogStore.save(practiceLapLogger.laps);
    _state = _state.copyWith(practiceLaps: practiceLapLogger.laps);
    _controller.add(_state);
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
