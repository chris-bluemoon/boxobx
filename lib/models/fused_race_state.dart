import 'telemetry_frame.dart';
import 'hud_overlay_data.dart';
import 'sector_state.dart';
import 'fuel_prediction.dart';
import 'tire_wear_estimate.dart';
import 'practice_lap_record.dart';
import 'shift_advice.dart';
import 'shift_event.dart';
import 'power_band_config.dart';
import 'opponent_pit_stop.dart';
import 'app_mode.dart';
import '../services/rejoin_forecaster.dart';

/// Where the driver is, from GT7's status flags (see TelemetryFlags).
/// [unknown] until the console has reported "car on track" at least once
/// -- until then the flags aren't trusted (see FusedRaceStateManager).
enum SessionPhase { unknown, driving, paused, offTrack }

/// Component C: single master state dictionary combining the Telemetry
/// Network Worker output with the HUD Screen Parser output and the
/// derived sector-split analytics.
class FusedRaceState {
  final TelemetryFrame telemetry;
  final HudOverlayData hud;
  final SectorState sectors;
  final FuelPrediction fuelPrediction;
  final TireWearEstimate tireWearEstimate;
  final List<ShiftEvent> recentShifts;

  /// Every completed practice lap this session (lap time, tire
  /// compound, fuel at start/end) -- see PracticeLapLogger. Persists
  /// across app restarts (see PracticeLogStore) so this list reflects
  /// ALL practice laps logged for the current round, not just this
  /// specific run of the app.
  final List<PracticeLapRecord> practiceLaps;

  /// Whether laps driven right now get logged/tagged to whichever
  /// round is currently saved, or are true FREE PRACTICE (not recorded
  /// at all) -- see FusedRaceStateManager.setPracticeLoggingEnabled.
  /// Defaults to true so existing behavior (every lap counts) is
  /// unchanged unless the driver explicitly opts out.
  final bool practiceLoggingEnabled;

  final SessionPhase sessionPhase;

  /// Shift window for the car GT7 reports (see PowerBandConfig.forCar).
  final PowerBandConfig powerBand;

  /// Other drivers' pit stops seen this session, oldest first (see
  /// PitLaneMonitor).
  final List<OpponentPitStop> opponentPitStops;

  /// Where the start/finish line is on the course map (0-1000 lap
  /// progress, same scale as TrafficMap), learned from where our marker
  /// was when telemetry's lap counter ticked over. Also assumed to be
  /// where the pits are. Null until we've crossed the line with the
  /// map tracking us.
  final double? startFinishLapProgress;

  /// Where the map showed us while our own "P" marker was up -- the
  /// pit box's position around the lap (0-1000). Null until we've
  /// pitted this session.
  final double? pitLapProgress;

  /// Traffic at the pit exit if we stopped now (see RejoinForecaster).
  final RejoinForecast? rejoinForecast;

  /// Practice or race (the dashboard toggle) -- tells Gunther which
  /// kind of session he's helping with.
  final AppMode mode;

  const FusedRaceState({
    required this.telemetry,
    required this.hud,
    required this.sectors,
    required this.fuelPrediction,
    required this.tireWearEstimate,
    this.recentShifts = const [],
    this.practiceLaps = const [],
    this.practiceLoggingEnabled = true,
    this.sessionPhase = SessionPhase.unknown,
    this.powerBand = PowerBandConfig.bmwM6Gt3Endurance,
    this.opponentPitStops = const [],
    this.startFinishLapProgress,
    this.pitLapProgress,
    this.rejoinForecast,
    this.mode = AppMode.practice,
  });

  factory FusedRaceState.initial() => FusedRaceState(
        telemetry: TelemetryFrame.empty(),
        hud: HudOverlayData.empty(),
        sectors: const SectorState(),
        fuelPrediction: FuelPrediction.insufficientData(),
        tireWearEstimate: TireWearEstimate.insufficientData(),
        recentShifts: const [],
        practiceLaps: const [],
        practiceLoggingEnabled: true,
      );

  FusedRaceState copyWith({
    TelemetryFrame? telemetry,
    HudOverlayData? hud,
    SectorState? sectors,
    FuelPrediction? fuelPrediction,
    TireWearEstimate? tireWearEstimate,
    List<ShiftEvent>? recentShifts,
    List<PracticeLapRecord>? practiceLaps,
    bool? practiceLoggingEnabled,
    SessionPhase? sessionPhase,
    PowerBandConfig? powerBand,
    List<OpponentPitStop>? opponentPitStops,
    double? startFinishLapProgress,
    bool clearStartFinishLapProgress = false,
    double? pitLapProgress,
    RejoinForecast? rejoinForecast,
    AppMode? mode,
  }) {
    return FusedRaceState(
      telemetry: telemetry ?? this.telemetry,
      hud: hud ?? this.hud,
      sectors: sectors ?? this.sectors,
      fuelPrediction: fuelPrediction ?? this.fuelPrediction,
      tireWearEstimate: tireWearEstimate ?? this.tireWearEstimate,
      recentShifts: recentShifts ?? this.recentShifts,
      practiceLaps: practiceLaps ?? this.practiceLaps,
      practiceLoggingEnabled: practiceLoggingEnabled ?? this.practiceLoggingEnabled,
      sessionPhase: sessionPhase ?? this.sessionPhase,
      powerBand: powerBand ?? this.powerBand,
      opponentPitStops: opponentPitStops ?? this.opponentPitStops,
      startFinishLapProgress:
          clearStartFinishLapProgress ? null : startFinishLapProgress ?? this.startFinishLapProgress,
      // Same lifetime as the start/finish point: per circuit/session.
      pitLapProgress: clearStartFinishLapProgress ? null : pitLapProgress ?? this.pitLapProgress,
      rejoinForecast: rejoinForecast ?? this.rejoinForecast,
      mode: mode ?? this.mode,
    );
  }

  /// Compact representation injected into the Gunther system prompt
  /// (Component B, Section 4) so the LLM has race-situational context.
  ///
  /// gapAheadTrend/gapBehindTrend ("closing"/"losing"/"steady") are the
  /// actually-useful strategy signal here -- the driver can already see
  /// who's ahead/behind by name directly on the GT7 HUD, so Gunther's
  /// value-add is calling out whether that gap is shrinking or growing,
  /// not repeating a name the driver can already read themselves.
  Map<String, dynamic> toPromptContext() => {
        'mode': mode.name,
        'speedKmh': telemetry.speedKmh.toStringAsFixed(0),
        'gear': telemetry.gear,
        'rpm': telemetry.rpm.toStringAsFixed(0),
        'throttlePercent': telemetry.throttlePercent.toStringAsFixed(0),
        'brakePercent': telemetry.brakePercent.toStringAsFixed(0),
        'sessionPhase': sessionPhase.name,
        'fuelPercent': telemetry.fuelPercent.toStringAsFixed(1),
        'tireTemps': telemetry.tireTemps,
        'gridPosition': hud.gridPosition,
        'driverAhead': hud.driverAhead,
        'gapAheadSeconds': hud.gapAheadSeconds,
        'gapAheadTrend': hud.gapAheadTrend.name,
        'driverBehind': hud.driverBehind,
        'gapBehindSeconds': hud.gapBehindSeconds,
        'gapBehindTrend': hud.gapBehindTrend.name,
        'gapToLeaderSeconds': hud.gapToLeaderSeconds,
        'gapToLeaderTrend': hud.gapToLeaderTrend.name,
        'currentSectorIndex': sectors.currentSectorIndex,
        'activeTrackName': sectors.activeTrackName,
        'currentLap': telemetry.currentLap,
        'predictedEmptyLap': fuelPrediction.predictedEmptyLap,
        'tireDegradationPercent': tireWearEstimate.percentSlowerThanStintBest,
        'consecutiveDegradingLaps': tireWearEstimate.consecutiveDegradingLaps,
        'practiceLapsLogged': practiceLaps.length,
        'shiftZone': ShiftAdvice.classify(telemetry.rpm, config: powerBand).zone.name,
        'driversInPitNow': hud.driversInPit.keys.toList(),
        'opponentPitStops': opponentPitStops.map((s) => s.toPromptContext()).toList(),
        'traffic': hud.traffic.toPromptContext(),
        'playerInPit': hud.playerInPit,
        'rejoinForecast': rejoinForecast?.toPromptContext(),
        'recentShiftTimings': recentShifts.map((s) => s.timing.name).toList(),
      };
}
