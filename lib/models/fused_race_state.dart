import '../services/race_rival_tracker.dart';
import '../services/stint_summary.dart';
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
import 'time_trial_lap.dart';
import '../services/corner_report.dart';
import '../services/race_lap_estimator.dart';
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

  /// Practice or race (the dashboard toggle) -- tells Boxington which
  /// kind of session he's helping with.
  final AppMode mode;

  /// Laps recorded in Time Trialing mode for the current round -- the
  /// qualifying-pace baseline (see TimeTrialLogger).
  final List<TimeTrialLap> timeTrialLaps;

  /// The latest clean lap against the reference lap, corner by corner
  /// (see CornerReport); null until there's one to compare.
  final CornerReport? cornerReport;

  /// How many laps the race is -- GT7's count, or an estimate in a timed
  /// race (see RaceLapEstimator). Null if unknown.
  final RaceLaps? raceLaps;

  /// The chosen race rival, as tracked (see RaceRivalTracker); null with
  /// no rival chosen or nothing seen yet.
  final RaceRivalState? raceRival;

  const FusedRaceState({
    required this.telemetry,
    required this.hud,
    required this.sectors,
    required this.fuelPrediction,
    required this.tireWearEstimate,
    this.recentShifts = const [],
    this.practiceLaps = const [],
    this.sessionPhase = SessionPhase.unknown,
    this.powerBand = PowerBandConfig.bmwM6Gt3Endurance,
    this.opponentPitStops = const [],
    this.startFinishLapProgress,
    this.pitLapProgress,
    this.rejoinForecast,
    this.mode = AppMode.practice,
    this.timeTrialLaps = const [],
    this.cornerReport,
    this.raceLaps,
    this.raceRival,
  });

  factory FusedRaceState.initial() => FusedRaceState(
    telemetry: TelemetryFrame.empty(),
    hud: HudOverlayData.empty(),
    sectors: const SectorState(),
    fuelPrediction: FuelPrediction.insufficientData(),
    tireWearEstimate: TireWearEstimate.insufficientData(),
    recentShifts: const [],
    practiceLaps: const [],
  );

  FusedRaceState copyWith({
    TelemetryFrame? telemetry,
    HudOverlayData? hud,
    SectorState? sectors,
    FuelPrediction? fuelPrediction,
    TireWearEstimate? tireWearEstimate,
    List<ShiftEvent>? recentShifts,
    List<PracticeLapRecord>? practiceLaps,
    SessionPhase? sessionPhase,
    PowerBandConfig? powerBand,
    List<OpponentPitStop>? opponentPitStops,
    double? startFinishLapProgress,
    bool clearStartFinishLapProgress = false,
    double? pitLapProgress,
    RejoinForecast? rejoinForecast,
    AppMode? mode,
    List<TimeTrialLap>? timeTrialLaps,
    CornerReport? cornerReport,
    RaceLaps? raceLaps,
    bool clearRaceLaps = false,
    RaceRivalState? raceRival,
    bool clearRaceRival = false,
  }) {
    return FusedRaceState(
      telemetry: telemetry ?? this.telemetry,
      hud: hud ?? this.hud,
      sectors: sectors ?? this.sectors,
      fuelPrediction: fuelPrediction ?? this.fuelPrediction,
      tireWearEstimate: tireWearEstimate ?? this.tireWearEstimate,
      recentShifts: recentShifts ?? this.recentShifts,
      practiceLaps: practiceLaps ?? this.practiceLaps,
      sessionPhase: sessionPhase ?? this.sessionPhase,
      powerBand: powerBand ?? this.powerBand,
      opponentPitStops: opponentPitStops ?? this.opponentPitStops,
      startFinishLapProgress: clearStartFinishLapProgress
          ? null
          : startFinishLapProgress ?? this.startFinishLapProgress,
      // Same lifetime as the start/finish point: per circuit/session.
      pitLapProgress: clearStartFinishLapProgress ? null : pitLapProgress ?? this.pitLapProgress,
      rejoinForecast: rejoinForecast ?? this.rejoinForecast,
      mode: mode ?? this.mode,
      timeTrialLaps: timeTrialLaps ?? this.timeTrialLaps,
      cornerReport: cornerReport ?? this.cornerReport,
      raceLaps: clearRaceLaps ? null : raceLaps ?? this.raceLaps,
      raceRival: clearRaceRival ? null : raceRival ?? this.raceRival,
    );
  }

  /// Compact representation injected into the Boxington system prompt
  /// (Component B, Section 4) so the LLM has race-situational context.
  ///
  /// gapAheadTrend/gapBehindTrend ("closing"/"losing"/"steady") are the
  /// actually-useful strategy signal here -- the driver can already see
  /// who's ahead/behind by name directly on the GT7 HUD, so Boxington's
  /// value-add is calling out whether that gap is shrinking or growing,
  /// not repeating a name the driver can already read themselves.
  Map<String, dynamic> toPromptContext() => {
    'mode': mode.name,
    ..._timeTrialContext(),
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
    if (sectors.lastLapSectorsMs != null)
      'lastLapSectorsSeconds': [for (final ms in sectors.lastLapSectorsMs!) (ms / 1000).toStringAsFixed(3)],
    'activeTrackName': sectors.activeTrackName,
    'currentLap': telemetry.currentLap,
    if (mode == AppMode.race && raceLaps != null) 'totalLaps': raceLaps!.total,
    if (mode == AppMode.race && (raceLaps?.estimated ?? false)) 'totalLapsEstimatedFromTimeLimit': true,
    'predictedEmptyLap': fuelPrediction.predictedEmptyLap,
    'tireDegradationPercent': tireWearEstimate.percentSlowerThanStintBest,
    'consecutiveDegradingLaps': tireWearEstimate.consecutiveDegradingLaps,
    'practiceLapsLogged': practiceLaps.length,
    if (mode == AppMode.practice && practiceLaps.isNotEmpty)
      'currentStint': StintSummary.fromLaps(practiceLaps).first.toPromptContext(),
    'shiftZone': ShiftAdvice.classify(telemetry.rpm, config: powerBand).zone.name,
    'driversInPitNow': hud.driversInPit.keys.toList(),
    'opponentPitStops': opponentPitStops.map((s) => s.toPromptContext()).toList(),
    'traffic': hud.traffic.toPromptContext(),
    'playerInPit': hud.playerInPit,
    'rejoinForecast': rejoinForecast?.toPromptContext(),
    if (mode == AppMode.race && raceRival != null) 'raceRival': raceRival!.toPromptContext(opponentPitStops),
    'recentShiftTimings': recentShifts.map((s) => s.timing.name).toList(),
  };

  /// Time-trial best (qualifying pace) and how the last lap compares --
  /// lets Boxington judge race pace against it.
  Map<String, dynamic> _timeTrialContext() {
    final best = TimeTrialLap.best(timeTrialLaps);
    if (best == null) return const {};
    final last = telemetry.lastLapTimeMs;
    return {
      'timeTrialBestLap': TimeTrialLap.format(best.lapTimeMs),
      if (SectorState.bestSectors(timeTrialLaps.map((l) => l.sectorsMs)) case final b when !b.contains(null))
        'timeTrialBestSectorsSeconds': [for (final ms in b) (ms! / 1000).toStringAsFixed(3)],
      if (last > 0) 'lastLapVsTimeTrialBestSeconds': ((last - best.lapTimeMs) / 1000).toStringAsFixed(2),
    };
  }
}
