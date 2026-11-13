import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import '../models/fused_race_state.dart';
import '../models/telemetry_frame.dart';
import '../models/connection_status.dart';
import '../models/voice_engine_status.dart';
import '../services/telemetry_udp_service.dart';
import '../services/hud_ocr_service.dart';
import '../services/sector_calculator.dart';
import '../services/fuel_predictor.dart';
import '../services/fused_race_state_manager.dart';
import '../services/push_to_talk_service.dart';
import '../services/groq_service.dart';
import '../services/tts_streaming_service.dart';
import '../services/native_audio_session_service.dart';
import '../services/voice_engine.dart';
import '../services/proactive_coach_trigger.dart';
import '../services/saved_briefing_store.dart';
import '../services/pit_stop_time_store.dart';
import '../services/rival_monitor.dart';
import '../models/shift_event.dart';
import 'race_strategy_screen.dart';
import 'practice_log_screen.dart';
import 'championship_screen.dart';
import '../widgets/telemetry_card.dart';
import '../widgets/tire_temp_card.dart';
import '../widgets/shift_card.dart';
import '../widgets/opponent_overlay.dart';
import '../widgets/push_to_talk_button.dart';
import '../widgets/status_badge.dart';
import '../widgets/voice_status_badge.dart';

/// Section 6: Hyper-minimalist, high-contrast, dark mode dashboard.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late final FusedRaceStateManager _raceStateManager;
  late final VoiceEngine _voiceEngine;
  final _shiftCoachTrigger = ProactiveCoachTrigger();
  final _rivalMonitor = RivalMonitor();

  FusedRaceState _state = FusedRaceState.initial();
  bool _telemetryEngaged = false;

  ConnectionStatus _telemetryStatus = ConnectionStatus.disconnected;
  ConnectionStatus _hudStatus = ConnectionStatus.disconnected;
  VoiceEngineStatus _voiceStatus = VoiceEngineStatus.idle;

  /// Last Whisper transcript, surfaced on-screen so it's obvious when
  /// "Gunther's response seems unrelated" is actually Whisper
  /// mis-transcribing noisy/silent mic input (very common on the iOS
  /// Simulator's virtual mic) rather than a bug in the LLM/TTS pipeline.
  String? _lastTranscript;

  /// Name of whichever round is currently saved in SavedBriefingStore
  /// (e.g. "Round 5") -- shown on the dashboard itself (not just inside
  /// the Race Strategy screen) so it's visible while actually driving
  /// practice laps which round's strategy they'll be validated
  /// against, since practice-lap data has no separate "tag" of its own
  /// -- it implicitly belongs to whichever round is currently saved.
  String? _activeRoundName;

  /// Tire compound currently selected on the dashboard's picker --
  /// applies to practice laps logged from now on (GT7's telemetry has
  /// no tire-compound field at all, so this manual selection is the
  /// only source of truth; see PracticeLapLogger).
  String _selectedTireCompound = 'Racing Medium';

  static const List<String> _tireCompoundOptions = [
    'Racing Hard',
    'Racing Medium',
    'Racing Soft',
    'Intermediate',
    'Heavy Wet',
  ];

  /// Maps the laptop OCR relay's raw compound code (read off GT7's HUD
  /// tire-wear widget -- see laptop_ocr/tire_wear_reader.py) to one of
  /// this dropdown's display strings. Only the compounds actually
  /// reachable from the dropdown are mapped; anything else (e.g. a
  /// comfort/sport-compound code, or a misread) is deliberately left
  /// unmapped so an unreliable read can never silently overwrite the
  /// driver's manual selection with the wrong compound.
  static const Map<String, String> _ocrCompoundToDropdownValue = {
    'RH': 'Racing Hard',
    'RM': 'Racing Medium',
    'RS': 'Racing Soft',
    'IM': 'Intermediate',
    'W': 'Heavy Wet',
  };

  /// Last OCR compound code this picker auto-applied, so a change is
  /// only ever auto-applied ONCE per new value read -- if the driver
  /// manually overrides the picker afterward (e.g. the OCR read is
  /// wrong), that manual choice sticks until the OCR reads something
  /// genuinely different again, rather than snapping back on every
  /// subsequent HUD update.
  String? _lastAutoAppliedOcrCompound;

  /// If the HUD OCR relay just read a (dropdown-mappable) tire
  /// compound that's different from the last one this picker
  /// auto-applied, updates both the dropdown's selection and the
  /// PracticeLapLogger's currentTireCompound to match -- the same two
  /// side effects the dropdown's own onChanged handler performs for a
  /// manual selection. Call this every time a new FusedRaceState comes
  /// in from the race-state stream.
  /// If any of the driver's chosen championship rivals (see
  /// ChampionshipScreen/RivalMonitor) just changed on-screen position,
  /// has Gunther call it out unprompted -- same proactive-callout
  /// mechanism ProactiveCoachTrigger uses for shift-habit callouts, but
  /// unconditionally enabled here (unlike the currently-disabled shift
  /// coaching) since this is Phase B's actual deliverable.
  void _maybeTriggerRivalPositionCallout(FusedRaceState state) {
    final syntheticPrompt = _rivalMonitor.check(state.hud.rivalPositions);
    if (syntheticPrompt == null) return;
    _voiceEngine.speakProactively(syntheticPrompt, state);
  }

  void _maybeAutoFillTireCompoundFromOcr(FusedRaceState state) {
    final ocrCompound = state.hud.tireCompound;
    if (ocrCompound == null) return;
    if (ocrCompound == _lastAutoAppliedOcrCompound) return;

    final mappedValue = _ocrCompoundToDropdownValue[ocrCompound];
    if (mappedValue == null) return;

    _lastAutoAppliedOcrCompound = ocrCompound;
    if (mappedValue == _selectedTireCompound) return;

    setState(() => _selectedTireCompound = mappedValue);
    _raceStateManager.setPracticeTireCompound(mappedValue);
  }

  @override
  void initState() {
    super.initState();

    _raceStateManager = FusedRaceStateManager(
      telemetryService: TelemetryUdpService(),
      hudService: HudOcrService(),
      sectorCalculator: SectorCalculator(),
      fuelPredictor: FuelPredictor(),
    );

    _loadActiveRoundName();

    _voiceEngine = VoiceEngine(
      pushToTalk: PushToTalkService(),
      groqService: GroqService(dotenv.env['GROQ_API_KEY'] ?? ''),
      ttsService: TtsStreamingService(
        apiKey: dotenv.env['TTS_API_KEY'] ?? '',
        voiceId: dotenv.env['TTS_VOICE_ID'] ?? '',
        provider: dotenv.env['TTS_PROVIDER'] ?? 'elevenlabs',
      ),
      audioSession: NativeAudioSessionService(),
    );

    _voiceEngine.initialize();

    _raceStateManager.stream.listen((state) {
      if (!mounted) return;
      setState(() => _state = state);
      _maybeAutoFillTireCompoundFromOcr(state);
      _maybeTriggerRivalPositionCallout(state);
      // Temporarily disabled -- proactive shift-habit voice callouts
      // aren't behaving correctly yet (reported live, not yet root
      // caused). Re-enable once fixed; the underlying trigger/advisor
      // logic and its tests are left in place untouched.
      // _maybeTriggerProactiveShiftCoaching(state);
    });

    _raceStateManager.telemetryStatusStream.listen((status) {
      if (!mounted) return;
      setState(() => _telemetryStatus = status);
    });

    _raceStateManager.hudStatusStream.listen((status) {
      if (!mounted) return;
      setState(() => _hudStatus = status);
    });

    _voiceEngine.statusStream.listen((status) {
      if (!mounted) return;
      setState(() => _voiceStatus = status);
    });

    _voiceEngine.transcripts.listen((transcript) {
      if (!mounted) return;
      setState(() => _lastTranscript = transcript);
    });
  }

  Future<void> _toggleTelemetry() async {
    if (_telemetryEngaged) {
      await _raceStateManager.stop();
    } else {
      final consoleIp = dotenv.env['CONSOLE_IP'] ?? '192.168.1.100';
      await _raceStateManager.start(consoleIp);
    }
    setState(() => _telemetryEngaged = !_telemetryEngaged);
  }

  /// GT7 keeps streaming valid, Salsa20-decryptable telemetry packets
  /// even after you exit a race/time trial back to the menu -- it just
  /// freezes the last known speed/gear/etc. rather than zeroing them, so
  /// the UDP connection stays "LIVE" with stale frozen values and no
  /// signal that you're no longer driving. This manually clears the
  /// displayed state back to its initial/zeroed values on demand (e.g.
  /// right after exiting a session) without touching the UDP connection
  /// itself -- the next real incoming frame will immediately overwrite
  /// this with fresh live data once you're driving again.
  /// Checks the latest fused state for a sustained short-shifting/
  /// over-revving pattern and, if the ProactiveCoachTrigger's pattern +
  /// cooldown gate says it's time, has Gunther call it out unprompted
  /// -- no push-to-talk needed. The synthetic prompt isn't shown to the
  /// driver; it just tells Gunther what to react to this time (see
  /// VoiceEngine.speakProactively).
  ///
  /// NOT currently called (see the commented-out call site above) --
  /// reported live as "not working properly" and temporarily disabled
  /// pending investigation. Left in place, with its tests, so it's a
  /// one-line re-enable once fixed.
  // ignore: unused_element
  void _maybeTriggerProactiveShiftCoaching(FusedRaceState state) {
    final badPattern = _shiftCoachTrigger.check(state.recentShifts);
    if (badPattern == null) return;

    final syntheticPrompt = badPattern == ShiftTiming.early
        ? 'The driver has been consistently short-shifting over their last several upshifts. Proactively call this out as a habit.'
        : 'The driver has been consistently over-revving before shifting over their last several upshifts. Proactively call this out as a habit.';

    _voiceEngine.speakProactively(syntheticPrompt, state);
  }

  /// Loads whichever round name is currently saved (see
  /// SavedBriefingStore), so the dashboard can show it while driving --
  /// refreshed after returning from the Race Strategy screen too, since
  /// the driver may have renamed/saved a different round there.
  Future<void> _loadActiveRoundName() async {
    final (name, briefing, _, _, _) = await SavedBriefingStore.load();
    if (!mounted || briefing == null) return;
    setState(() => _activeRoundName = name);
  }

  Future<void> _openPracticeLog() async {
    final pitStopTimeRecords = await PitStopTimeStore.load();
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PracticeLogScreen(
          laps: _state.practiceLaps,
          pitStopTimeRecords: pitStopTimeRecords,
          onClear: () {
            _raceStateManager.clearPracticeLaps();
            Navigator.of(context).pop();
          },
          onDeleteLap: (recordedAt) => _raceStateManager.removePracticeLap(recordedAt),
        ),
      ),
    );
  }

  /// Opens the pre-race strategy planner, passing a getter for the
  /// current live FuelPrediction so strategy generation can fall back
  /// to the SAME live data this dashboard is already tracking (when
  /// not enough clean practice laps exist for the shift-aware average)
  /// without needing its own telemetry connection.
  Future<void> _openRaceStrategy() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RaceStrategyScreen(
          getCurrentFuelPrediction: () => _state.fuelPrediction,
          getPracticeLaps: () => _state.practiceLaps,
        ),
      ),
    );
    // The driver may have saved a (re)named round while on that screen
    // -- refresh the dashboard's badge so it reflects whichever round
    // practice laps now count toward.
    _loadActiveRoundName();
  }

  /// Opens the weekly league championship standings entry + rival
  /// selection screen (Phase A of the "nearest rival" feature -- see
  /// ChampionshipScreen's own docstring for what Phase B adds on top).
  Future<void> _openChampionship() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ChampionshipScreen()),
    );
  }

  void _resetTelemetryDisplay() {
    _raceStateManager.resetFuelPrediction();
    _raceStateManager.resetTireWearEstimate();
    _raceStateManager.resetShiftHistory();
    _shiftCoachTrigger.reset();
    // Clears tracked rival positions too -- otherwise a rival's LAST
    // position from a previous race would be compared against this
    // new session's first reading and fire a spurious "rival moved"
    // callout purely from the session boundary, not a real on-track
    // change.
    _rivalMonitor.reset();
    setState(() {
      _state = _state.copyWith(telemetry: TelemetryFrame.empty(), recentShifts: const []);
    });
  }

  @override
  void dispose() {
    _raceStateManager.dispose();
    _voiceEngine.dispose();
    super.dispose();
  }

  bool get _positionAlert => _state.sectors.currentSectorIndex == 0 && _state.hud.gridPosition > 0;

  /// Replaces the old raw FUEL% card -- that percentage is already shown
  /// directly on GT7's own HUD, so showing it a second time here wasted
  /// dashboard space. The predicted pit lap (derived by FuelPredictor
  /// from per-lap consumption) is something the driver can't read off
  /// the game screen directly.
  String _pitLapDisplayValue() {
    final prediction = _state.fuelPrediction;
    if (!prediction.hasEnoughData || prediction.predictedEmptyLap == null) {
      return '--';
    }
    return 'L${prediction.predictedEmptyLap}';
  }

  /// Flashes red once the predicted empty lap is close (within 2 laps),
  /// mirroring the urgency the old low-fuel-percent alert conveyed.
  bool _pitLapAlert() {
    final prediction = _state.fuelPrediction;
    if (!prediction.hasEnoughData || prediction.predictedEmptyLap == null) {
      return false;
    }
    final lapsRemaining = prediction.predictedEmptyLap! - _state.telemetry.currentLap;
    return lapsRemaining <= 2;
  }

  @override
  Widget build(BuildContext context) {
    final telemetry = _state.telemetry;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  StatusBadge(label: 'TELEMETRY', status: _telemetryStatus),
                  StatusBadge(label: 'HUD OCR', status: _hudStatus),
                  VoiceStatusBadge(status: _voiceStatus),
                  if (_activeRoundName != null)
                    InkWell(
                      onTap: () => _raceStateManager
                          .setPracticeLoggingEnabled(!_state.practiceLoggingEnabled),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: _state.practiceLoggingEnabled
                              ? Colors.purple.shade700
                              : Colors.grey.shade800.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: _state.practiceLoggingEnabled ? Colors.purple.shade400 : Colors.grey.shade700,
                          ),
                        ),
                        child: Text(
                          _state.practiceLoggingEnabled
                              ? 'PRACTICING FOR: $_activeRoundName'
                              : 'FREE PRACTICE (tap to resume $_activeRoundName)',
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('TIRE:', style: TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade900,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedTireCompound,
                          isExpanded: true,
                          dropdownColor: Colors.grey.shade900,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          items: _tireCompoundOptions
                              .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() => _selectedTireCompound = value);
                            _raceStateManager.setPracticeTireCompound(value);
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: _openPracticeLog,
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade900.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.blue.shade700),
                      ),
                      child: Text(
                        '${_state.practiceLaps.length} LAPS LOGGED',
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: ElevatedButton(
                      onPressed: _toggleTelemetry,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _telemetryEngaged ? Colors.green.shade700 : Colors.grey.shade800,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: Text(
                        _telemetryEngaged ? 'TELEMETRY ENGAGED' : 'ENGAGE TELEMETRY',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 1,
                    child: ElevatedButton(
                      onPressed: _resetTelemetryDisplay,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.grey.shade800,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: const Icon(Icons.refresh, color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 1,
                    child: ElevatedButton(
                      onPressed: _openRaceStrategy,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.purple.shade800,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: const Icon(Icons.flag, color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 1,
                    child: ElevatedButton(
                      onPressed: _openChampionship,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber.shade800,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: const Icon(Icons.emoji_events, color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                flex: 3,
                child: Column(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            child: TireTempCard(
                              tireTemps: telemetry.tireTemps,
                              tireWearPercents: [
                                _state.hud.tireWearFrontLeftPercent,
                                _state.hud.tireWearFrontRightPercent,
                                _state.hud.tireWearRearLeftPercent,
                                _state.hud.tireWearRearRightPercent,
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ShiftCard(
                              gear: telemetry.gear,
                              recentShifts: _state.recentShifts,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            child: TelemetryCard(
                              label: 'PIT LAP',
                              value: _pitLapDisplayValue(),
                              alert: _pitLapAlert(),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TelemetryCard(
                              label: 'POSITION',
                              value: 'P${_state.hud.gridPosition}',
                              alert: _positionAlert,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              OpponentOverlay(hud: _state.hud),
              if (_lastTranscript != null) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade900,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade800),
                  ),
                  child: Text(
                    'Heard: "$_lastTranscript"',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 13, fontStyle: FontStyle.italic),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Expanded(
                flex: 2,
                child: PushToTalkButton(
                  onPressStart: _voiceEngine.onPushToTalkPressed,
                  onPressEnd: () => _voiceEngine.onPushToTalkReleased(_state),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
