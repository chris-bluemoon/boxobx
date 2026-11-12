import 'telemetry_frame.dart';
import 'hud_overlay_data.dart';
import 'sector_state.dart';
import 'fuel_prediction.dart';
import 'tire_wear_estimate.dart';
import 'practice_lap_record.dart';
import 'shift_advice.dart';
import 'shift_event.dart';

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

  const FusedRaceState({
    required this.telemetry,
    required this.hud,
    required this.sectors,
    required this.fuelPrediction,
    required this.tireWearEstimate,
    this.recentShifts = const [],
    this.practiceLaps = const [],
    this.practiceLoggingEnabled = true,
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
        'speedKmh': telemetry.speedKmh.toStringAsFixed(0),
        'gear': telemetry.gear,
        'rpm': telemetry.rpm.toStringAsFixed(0),
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
        'shiftZone': ShiftAdvice.classify(telemetry.rpm).zone.name,
        'recentShiftTimings': recentShifts.map((s) => s.timing.name).toList(),
      };
}
