import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import '../models/fused_race_state.dart';
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
import '../services/rival_monitor.dart';
import '../models/shift_event.dart';
import '../models/opponent_pit_stop.dart';
import '../services/rejoin_forecaster.dart';
import '../services/pit_call_advisor.dart';
import '../services/test_plan_tracker.dart';
import '../services/stint_summary.dart';
import '../services/race_report.dart';
import '../services/corner_report.dart';
import '../models/test_plan.dart';
import '../services/app_mode_store.dart';
import '../models/app_mode.dart';
import '../models/sector_state.dart';
import '../models/time_trial_lap.dart';
import '../models/race_strategy.dart';
import 'race_strategy_screen.dart';
import 'practice_log_screen.dart';
import 'championship_screen.dart';
import 'race_reports_screen.dart';
import 'corner_report_screen.dart';
import '../widgets/telemetry_card.dart';
import '../widgets/tire_temp_card.dart';
import '../widgets/shift_card.dart';
import '../widgets/opponent_overlay.dart';
import '../widgets/push_to_talk_button.dart';
import '../widgets/status_badge.dart';
import '../widgets/box_box_logo.dart';
import '../widgets/track_header.dart';
import '../services/track_outlines.dart';
import '../models/league_calendar.dart';
import '../widgets/voice_status_badge.dart';

/// Section 6: Hyper-minimalist, high-contrast, dark mode dashboard.
class DashboardScreen extends StatefulWidget {
  /// Connect to the console and the laptop relay as soon as the
  /// dashboard opens. Off only in widget tests, which shouldn't open
  /// real network sockets.
  final bool connectOnStart;

  const DashboardScreen({super.key, this.connectOnStart = true});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late final FusedRaceStateManager _raceStateManager;
  late final VoiceEngine _voiceEngine;
  final _shiftCoachTrigger = ProactiveCoachTrigger();
  final _rivalMonitor = RivalMonitor();
  final _pitCallAdvisor = PitCallAdvisor();
  final _testPlanCaller = TestPlanCaller();

  /// The practice test plan for the saved round (see TestPlan), built
  /// from its briefing; null with no round saved.
  TestPlan? _testPlan;

  /// Stops in the saved strategy, loaded with the round name (see
  /// _loadActiveRoundName) -- what PitCallAdvisor's planned-stop window
  /// is measured against.
  List<PlannedPitStop> _plannedStops = const [];

  /// The saved round's strategy, for the race reports' plan comparison.
  RaceStrategy? _savedStrategy;

  /// Practice or race (see AppMode) -- gates the race-only unprompted
  /// calls and widgets. Remembered between launches.
  AppMode _mode = AppMode.practice;

  /// True while the launch page (Race Mode / Stint Testing / Time
  /// Trialing) is showing -- at every launch, and again when the mode
  /// chip is tapped. The connection stays up meanwhile; unprompted calls
  /// are held.
  bool _choosingMode = true;

  Future<void> _loadMode() async {
    final mode = await AppModeStore.load();
    if (!mounted) return;
    setState(() => _mode = mode);
    _raceStateManager.setMode(mode);
  }

  void _setMode(AppMode mode) {
    setState(() => _choosingMode = false);
    if (mode == _mode) return;
    setState(() => _mode = mode);
    _raceStateManager.setMode(mode);
    AppModeStore.save(mode);
    // Nothing queued in one mode should be spoken in the other.
    _voiceEngine.clearQueuedCallouts();
  }

  FusedRaceState _state = FusedRaceState.initial();

  ConnectionStatus _telemetryStatus = ConnectionStatus.disconnected;
  ConnectionStatus _hudStatus = ConnectionStatus.disconnected;
  VoiceEngineStatus _voiceStatus = VoiceEngineStatus.idle;

  /// Last Whisper transcript, surfaced on-screen so it's obvious when
  /// "Boxington's response seems unrelated" is actually Whisper
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
  /// has Boxington call it out unprompted -- same proactive-callout
  /// mechanism ProactiveCoachTrigger uses for shift-habit callouts, but
  /// unconditionally enabled here (unlike the currently-disabled shift
  /// coaching) since this is Phase B's actual deliverable.
  void _maybeTriggerRivalPositionCallout(FusedRaceState state) {
    final syntheticPrompt = _rivalMonitor.check(state.hud.rivalPositions);
    // Still checked in practice so tracking stays current; just not spoken.
    if (syntheticPrompt == null || !_mode.rivalCallouts || _choosingMode) return;
    _voiceEngine.speakProactively(syntheticPrompt, state);
  }

  /// Boxington's test-plan call (Practice Mode): the running test has
  /// reached its target.
  void _maybeMakeTestPlanCall(FusedRaceState state) {
    final plan = _testPlan;
    if (plan == null || !_mode.testPlan || _choosingMode) return;
    final logger = _raceStateManager.practiceLapLogger;
    final prompt = _testPlanCaller.check(
      plan,
      state.practiceLaps,
      activeTestNumber: logger.activeTestNumber,
      currentStintNumber: logger.currentStint,
      liveWearRemaining: logger.currentTireWearPercent,
      liveFuelPercent: state.sessionPhase == SessionPhase.driving ? state.telemetry.fuelPercent : null,
    );
    if (prompt == null) return;

    // Once Boxington has finished saying it (or after 15s, should the voice
    // fail), the test is closed off automatically -- nothing to tap --
    // and the panel moves on to the next test.
    final testNumber = logger.activeTestNumber;
    final completed = plan.stints.where((s) => s.number == testNumber).firstOrNull;
    var closed = false;
    void closeTest() {
      if (closed || !mounted) return;
      closed = true;
      if (logger.activeTestNumber != testNumber) return; // ended/changed meanwhile
      _raceStateManager.completeActiveTest();
      setState(() => _justCompletedTest = completed);
    }

    _voiceEngine.speakProactively(prompt, state).whenComplete(closeTest);
    Timer(const Duration(seconds: 15), closeTest);
  }

  /// Time Trialing: after each clean lap, Boxington names the corner where
  /// the most time went against the reference lap and what to change
  /// (see CornerReport) -- once per lap, and only if it's worth saying.
  void _maybeMakeCornerCall(FusedRaceState state) {
    final report = state.cornerReport;
    if (report == null || identical(report, _lastCalledCornerReport)) return;
    _lastCalledCornerReport = report;
    if (!_mode.cornerCalls || _choosingMode) return;
    final worst = report.biggestLoss;
    if (worst == null || worst.timeDeltaMs < _cornerCallMinLossMs) return;
    final gap = report.lapDeltaMs / 1000;
    _voiceEngine.speakProactively(
      'Time-trial lap done, ${gap >= 0 ? '+' : ''}${gap.toStringAsFixed(2)} seconds to the reference lap. '
      'Biggest loss against the reference: ${worst.describe()}. '
      'In one short sentence, tell the driver which corner cost the most and the one thing to change there. '
      'Say the corner number; do not read out every figure.',
      state,
    );
  }

  CornerReport? _lastCalledCornerReport;

  /// Losses smaller than this (ms) aren't worth a call.
  static const _cornerCallMinLossMs = 50;

  void _openCornerReport() {
    final report = _state.cornerReport;
    if (report == null) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => CornerReportScreen(report: report)));
  }

  /// The test Boxington last called complete -- shown on the panel until
  /// the next test starts.
  PlannedTestStint? _justCompletedTest;

  TestPlanProgress _testPlanProgress(TestPlan plan) => TestPlanTracker.progress(
    plan,
    _state.practiceLaps,
    activeTestNumber: _raceStateManager.practiceLapLogger.activeTestNumber,
  );

  Future<void> _confirmStartTest(PlannedTestStint test) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: Text('Start test ${test.number}?', style: const TextStyle(color: Colors.white)),
        content: Text(
          '${_testPlanProgress(_testPlan!).targetFor(test)}\n\nYour next lap starts this test. Fit ${test.compoundShort}s with '
          '${test.startFuelPercent.toStringAsFixed(0)}% fuel.',
          style: TextStyle(color: Colors.grey.shade300),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Start')),
        ],
      ),
    );
    if (ok == true) _startTest(test);
  }

  /// Starts [test]: a new stint tagged to it, with the tyre picker set to
  /// the planned compound. The app takes the driver's word for it.
  void _startTest(PlannedTestStint test) {
    _justCompletedTest = null;
    _raceStateManager.startTestStint(test.number);
    _testPlanCaller.reset();
    if (_tireCompoundOptions.contains(test.compound)) {
      setState(() => _selectedTireCompound = test.compound);
      _raceStateManager.setPracticeTireCompound(test.compound);
    } else {
      setState(() {});
    }
  }

  Future<void> _confirmEndTest(PlannedTestStint test) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: Text('End test ${test.number}?', style: const TextStyle(color: Colors.white)),
        content: Text(
          'Your next lap starts a normal stint. The test only counts if it reached its target.',
          style: TextStyle(color: Colors.grey.shade300),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('End test')),
        ],
      ),
    );
    if (ok == true) {
      _raceStateManager.startNewStint();
      setState(() {});
    }
  }

  /// Lists every test, with its status, to start any of them.
  Future<void> _pickTest(TestPlan plan) async {
    final progress = _testPlanProgress(plan);
    final picked = await showModalBottomSheet<PlannedTestStint>(
      context: context,
      backgroundColor: Colors.grey.shade900,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final (i, test) in plan.stints.indexed)
              ListTile(
                leading: Icon(switch (progress.statuses[i]) {
                  TestStatus.done => Icons.check_circle,
                  TestStatus.inProgress => Icons.play_circle,
                  TestStatus.toDo => Icons.radio_button_unchecked,
                }, color: progress.statuses[i] == TestStatus.done ? Colors.greenAccent : Colors.grey.shade400),
                title: Text(
                  'Test ${test.number}: ${progress.targetFor(test)}',
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: Text(test.purpose, style: TextStyle(color: Colors.grey.shade500)),
                onTap: () => Navigator.pop(context, test),
              ),
          ],
        ),
      ),
    );
    if (picked != null) _startTest(picked);
  }

  /// e.g. "STINT 2 · 5 LAPS (23 TOTAL)" once stints exist.
  String _lapsChipLabel() {
    final laps = _state.practiceLaps;
    final stint = _raceStateManager.practiceLapLogger.currentStint;
    if (stint == 0) return '${laps.length} LAPS LOGGED';
    final inStint = laps.where((l) => l.stintNumber == stint).length;
    return 'STINT $stint · $inStint LAPS (${laps.length} TOTAL)';
  }

  void _startNewStint() {
    _raceStateManager.startNewStint();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Your next lap starts a new stint'), duration: Duration(seconds: 2)));
  }

  /// Unprompted "box / stay out" call when a stop is due -- see
  /// PitCallAdvisor for when it fires and what it recommends.
  void _maybeMakePitCall(FusedRaceState state) {
    if (!_mode.pitCalls || _choosingMode) return;
    final call = _pitCallAdvisor.check(
      state,
      plannedStops: _plannedStops,
      pitLapsThisSession: _raceStateManager.pitStopTracker.pitLaps,
    );
    if (call != null) _voiceEngine.speakProactively(call.toPrompt(), state);
  }

  /// PRACTICE / RACE switch -- tap to flip.
  static Color _modeColour(AppMode mode) => switch (mode) {
    AppMode.race => Colors.red.shade800,
    AppMode.practice => Colors.teal.shade800,
    AppMode.timeTrial => Colors.deepPurple.shade700,
  };

  static String _modeDescription(AppMode mode) => switch (mode) {
    AppMode.race => 'Race calls, pit strategy, traffic and Boxington',
    AppMode.practice => 'Run the test plan: full-tank stints per compound',
    AppMode.timeTrial => 'Qualifying pace: lap times only, as your baseline',
  };

  static IconData _modeIcon(AppMode mode) => switch (mode) {
    AppMode.race => Icons.sports_score,
    AppMode.practice => Icons.science,
    AppMode.timeTrial => Icons.timer,
  };

  /// Every race run in Race Mode this round, with a report for each.
  Future<void> _openRaceReports() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RaceReportsScreen(
          laps: _state.practiceLaps,
          strategy: _savedStrategy,
          timeTrialBest: TimeTrialLap.best(_state.timeTrialLaps),
          roundName: _activeRoundName,
        ),
      ),
    );
  }

  /// The launch page: the three modes as large buttons.
  Widget _modeChooser() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: BoxBoxLogo(size: 40, tagline: 'YOUR GT7 ENGINEER'),
              ),
              const SizedBox(height: 16),
              _trackHeader(accent: Colors.blueGrey.shade600, large: true),
              const SizedBox(height: 16),
              for (final mode in AppMode.values) ...[
                Expanded(
                  child: InkWell(
                    onTap: () => _setMode(mode),
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                      decoration: BoxDecoration(
                        color: _modeColour(mode),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: mode == _mode ? Colors.white : Colors.white24, width: 2),
                      ),
                      child: Row(
                        children: [
                          Icon(_modeIcon(mode), color: Colors.white, size: 56),
                          const SizedBox(width: 24),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  mode.label,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 28,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _modeDescription(mode),
                                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                                ),
                              ],
                            ),
                          ),
                          if (mode == _mode)
                            const Text('LAST USED', style: TextStyle(color: Colors.white70, fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Row(
                children: [
                  _homeButton(Icons.flag, 'RACE STRATEGY', _openRaceStrategy),
                  const SizedBox(width: 12),
                  _homeButton(Icons.emoji_events, 'STANDINGS', _openChampionship),
                  const SizedBox(width: 12),
                  _homeButton(
                    Icons.assessment,
                    'RACE REPORTS (${RaceReport.fromLaps(_state.practiceLaps).length})',
                    _openRaceReports,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _connectionBadges(),
            ],
          ),
        ),
      ),
    );
  }

  /// Console (telemetry) and laptop relay (HUD OCR) connection status --
  /// always bottom left, on the home page and every mode's screen.
  Widget _connectionBadges({bool boxington = false}) => Align(
    alignment: Alignment.centerLeft,
    child: Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        StatusBadge(label: 'TELEMETRY', status: _telemetryStatus),
        StatusBadge(label: 'HUD OCR', status: _hudStatus),
        // Boxington only speaks in practice to end a test, so his status
        // belongs to the race screen.
        if (boxington) VoiceStatusBadge(status: _voiceStatus),
      ],
    ),
  );

  void _goHome() => setState(() => _choosingMode = true);

  /// A home-page button for the round's setup and records.
  Widget _homeButton(IconData icon, String label, VoidCallback onPressed) => Expanded(
    child: OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, color: Colors.white),
      label: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
      ),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 18),
        side: const BorderSide(color: Colors.white38),
      ),
    ),
  );

  /// Race screen: the last lap against the time-trial best (qualifying
  /// pace), e.g. "TT BEST 1:29.950 · LAST +1.23s".
  Widget? _timeTrialComparisonChip() {
    final best = TimeTrialLap.best(_state.timeTrialLaps);
    if (best == null) return null;
    final last = _state.telemetry.lastLapTimeMs;
    final delta = last > 0 ? (last - best.lapTimeMs) / 1000 : null;
    return _chip(
      'TT BEST ${TimeTrialLap.format(best.lapTimeMs)}'
      '${delta == null ? '' : ' · LAST ${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(2)}s'}',
      color: Colors.deepPurple.shade700.withValues(alpha: 0.6),
      border: Colors.deepPurple.shade300,
    );
  }

  /// "If I boxed now" at a glance: green when we'd rejoin in clear air,
  /// amber with the nearest car's gap when we'd come out in traffic.
  Widget _rejoinChip(RejoinForecast forecast) {
    final nearest = forecast.rejoinTraffic.isEmpty ? null : forecast.rejoinTraffic.first;
    final label = forecast.clearAir
        ? 'BOX NOW: CLEAR AIR'
        : 'BOX NOW: CAR ${nearest!.abs().toStringAsFixed(1)}s ${nearest >= 0 ? 'BEHIND' : 'AHEAD'}';
    final colour = forecast.clearAir ? Colors.green.shade700 : Colors.amber.shade800;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: colour, borderRadius: BorderRadius.circular(16)),
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
      ),
    );
  }

  /// Synthetic prompt for Boxington when other drivers enter the pits.
  /// Championship rivals (those the relay tracks positions for) are
  /// flagged so he can treat them as the priority.
  String _opponentPitCalloutPrompt(List<OpponentPitStop> stops) {
    final rivals = _state.hud.rivalPositions.keys.toSet();
    final descriptions = stops
        .map((s) {
          final details = [
            if (s.position != null) 'P${s.position}',
            if (OpponentPitStop.tyreName(s.tyre) != null) 'fitting ${OpponentPitStop.tyreName(s.tyre)}',
            if (s.fuel != null) 'taking ${s.fuel} fuel',
          ];
          final who = rivals.contains(s.driver) ? 'championship rival ${s.driver}' : s.driver;
          return details.isEmpty ? who : '$who (${details.join(', ')})';
        })
        .join('; ');
    final verb = stops.length == 1 ? 'is' : 'are';
    return '$descriptions $verb in the pits on our lap ${_state.telemetry.currentLap}. '
        'Call it out briefly, with what it means for us if anything.';
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
    _loadMode();
    TrackOutlines.load().then((outlines) {
      if (mounted) setState(() => _trackOutlines = outlines);
    });

    _voiceEngine = VoiceEngine(
      pushToTalk: PushToTalkService(),
      groqService: GroqService(dotenv.env['GROQ_API_KEY'] ?? ''),
      ttsService: TtsStreamingService(
        apiKey: dotenv.env['TTS_API_KEY'] ?? '',
        voiceId: dotenv.env['TTS_VOICE_ID'] ?? '',
        provider: dotenv.env['TTS_PROVIDER'] ?? 'elevenlabs',
      ),
      audioSession: NativeAudioSessionService(),
      latestRaceState: () => _state,
    );

    _voiceEngine.initialize();

    _raceStateManager.stream.listen((state) {
      if (!mounted) return;
      _trackPositionLoss(state.hud.gridPosition);
      setState(() => _state = state);
      _maybeAutoFillTireCompoundFromOcr(state);
      _maybeTriggerRivalPositionCallout(state);
      _maybeMakePitCall(state);
      _maybeMakeTestPlanCall(state);
      _maybeMakeCornerCall(state);
      // Temporarily disabled -- proactive shift-habit voice callouts
      // aren't behaving correctly yet (reported live, not yet root
      // caused). Re-enable once fixed; the underlying trigger/advisor
      // logic and its tests are left in place untouched.
      // _maybeTriggerProactiveShiftCoaching(state);
    });

    // Restore saved laps/pit-loss now, not on ENGAGE TELEMETRY -- after
    // the listener above is attached, so the restored state reaches it.
    _raceStateManager.loadPersistedData();

    // No ENGAGE TELEMETRY button: connect straight away. GT7 streams to
    // whoever sent the latest heartbeat, and the heartbeat repeats every
    // second, so this goes live whenever the PS5/GT7 is ready -- even if
    // the app was opened first.
    if (widget.connectOnStart) {
      _raceStateManager.start(dotenv.env['CONSOLE_IP'] ?? '192.168.1.100');
    }

    // Leaving the track (race over, exiting to the menu, loading the
    // next session) now resets per-session state automatically -- the
    // refresh button is only needed if GT7's flags aren't available.
    _raceStateManager.sessionEnded.listen((_) => _resetSessionTracking());

    _raceStateManager.opponentPitted.listen((stops) {
      // Stops are logged in both modes; only called out in a race.
      if (!_mode.opponentPitCallouts || _choosingMode) return;
      _voiceEngine.speakProactively(_opponentPitCalloutPrompt(stops), _state);
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
  /// cooldown gate says it's time, has Boxington call it out unprompted
  /// -- no push-to-talk needed. The synthetic prompt isn't shown to the
  /// driver; it just tells Boxington what to react to this time (see
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
    final (name, briefing, strategy, _, _) = await SavedBriefingStore.load();
    if (!mounted) return;
    _plannedStops = strategy?.pitStops ?? const [];
    _savedStrategy = strategy;
    _testPlan = briefing == null
        ? null
        : TestPlan.fromBriefing(briefing, startCompound: strategy?.startingTireCompound);
    _raceStateManager.setPitStopTime(briefing?.pitStopTimeSeconds);
    _raceStateManager.setRound(name);
    _raceStateManager.setRaceLength(minutes: briefing?.raceLengthMinutes, plannedLaps: briefing?.totalLaps);
    if (briefing == null) return;
    setState(() {
      _activeRoundName = name;
      _activeTrackName = briefing.trackName;
    });
  }

  /// The GT7 track of the saved round, for the header's circuit emblem.
  String? _activeTrackName;

  /// Circuit outlines for the header emblems (loaded once at start).
  TrackOutlines? _trackOutlines;

  /// The page heading: round, circuit emblem and the page's own title.
  Widget _trackHeader({
    required Color accent,
    String? pageTitle,
    IconData? pageIcon,
    VoidCallback? onPageTitleTap,
    bool large = false,
  }) {
    final round = _activeRoundName == null ? null : LeagueCalendar.byName(_activeRoundName!);
    return TrackHeader(
      roundName: _activeRoundName,
      round: round,
      outline: _trackOutlines?.forTrack(_activeTrackName ?? round?.gt7Track),
      accent: accent,
      pageTitle: pageTitle,
      pageIcon: pageIcon,
      onPageTitleTap: onPageTitleTap,
      large: large,
    );
  }

  Future<void> _openPracticeLog() async {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PracticeLogScreen(
          laps: _state.practiceLaps,
          roundName: _activeRoundName,
          testPlan: _testPlan,
          activeTestNumber: _raceStateManager.practiceLapLogger.activeTestNumber,
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
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ChampionshipScreen()));
  }

  /// Dashboard-owned per-session state, reset automatically when GT7
  /// reports leaving the track (FusedRaceStateManager.sessionEnded).
  void _resetSessionTracking() {
    _shiftCoachTrigger.reset();
    // Clears tracked rival positions too -- otherwise a rival's LAST
    // position from a previous race would be compared against this
    // new session's first reading and fire a spurious "rival moved"
    // callout purely from the session boundary, not a real on-track
    // change.
    _rivalMonitor.reset();
    _pitCallAdvisor.reset();
    _testPlanCaller.reset();
    _voiceEngine.clearQueuedCallouts();
    _lastGridPosition = null;
    _positionLostAt = null;
  }

  @override
  void dispose() {
    _raceStateManager.dispose();
    _voiceEngine.dispose();
    super.dispose();
  }

  /// How long the POSITION card stays red after losing a place.
  static const Duration _positionLostAlertDuration = Duration(seconds: 3);

  int? _lastGridPosition;
  DateTime? _positionLostAt;

  /// Records when the driver last LOST a place (position number went
  /// up). The relay already debounces gridPosition (see
  /// GridPositionStabilizer in ocr_relay.py), so a change here is a
  /// real one. 0 means "not read" and is ignored.
  void _trackPositionLoss(int gridPosition) {
    if (gridPosition <= 0) return;
    final last = _lastGridPosition;
    if (last != null && gridPosition > last) _positionLostAt = DateTime.now();
    _lastGridPosition = gridPosition;
  }

  /// Red for a few seconds after losing a place. This previously keyed
  /// off currentSectorIndex == 0, but GT7 telemetry has no track
  /// length, so the sector calculator never advances and the card was
  /// permanently red whenever a position was read. Re-evaluated on
  /// every rebuild, which telemetry drives at up to 60Hz, so it clears
  /// on its own without a timer.
  bool get _positionAlert {
    final lostAt = _positionLostAt;
    return lostAt != null && DateTime.now().difference(lostAt) < _positionLostAlertDuration;
  }

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
    if (_choosingMode) return _modeChooser();
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _trackHeader(
                accent: _modeColour(_mode),
                pageTitle: _mode.label,
                pageIcon: _modeIcon(_mode),
                onPageTitleTap: _goHome,
              ),
              const SizedBox(height: 10),
              Align(alignment: Alignment.centerLeft, child: _statusBar()),
              const SizedBox(height: 10),
              Expanded(
                child: switch (_mode) {
                  AppMode.race => _raceBody(),
                  AppMode.practice => _practiceBody(),
                  AppMode.timeTrial => _timeTrialBody(),
                },
              ),
              const SizedBox(height: 12),
              // Bottom bar: connection (and, racing, Boxington) status on the
              // left, as on the home page; HOME on the right.
              Row(
                children: [
                  Expanded(child: _connectionBadges(boxington: _mode == AppMode.race)),
                  OutlinedButton.icon(
                    onPressed: _goHome,
                    icon: const Icon(Icons.home, color: Colors.white),
                    label: const Text(
                      'HOME',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.5),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white38),
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- shared -------------------------------------------------------------

  Widget _chip(String label, {required Color color, Color? border, VoidCallback? onTap}) {
    final box = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
        border: border == null ? null : Border.all(color: border),
      ),
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
      ),
    );
    return onTap == null ? box : InkWell(onTap: onTap, borderRadius: BorderRadius.circular(16), child: box);
  }

  Widget _statusBar() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (_mode.trafficChip && _state.rejoinForecast != null && !_state.hud.playerInPit)
          _rejoinChip(_state.rejoinForecast!),
        if (_telemetryStatus == ConnectionStatus.live &&
            (_state.sessionPhase == SessionPhase.paused || _state.sessionPhase == SessionPhase.offTrack))
          _chip(_state.sessionPhase == SessionPhase.paused ? 'PAUSED' : 'OFF TRACK', color: Colors.grey.shade800),
        if (_mode == AppMode.race) ?_timeTrialComparisonChip(),
      ],
    );
  }

  /// Stint Testing's tyre row: the tyre laps are being logged on,
  /// read-only (the relay reads it off the HUD, and starting a test sets
  /// it), plus the laps chip and NEW STINT.
  Widget _tyreRow() {
    return Row(
      children: [
        const Text(
          'TIRE:',
          style: TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _selectedTireCompound,
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(width: 8),
        _chip(
          _lapsChipLabel(),
          color: Colors.blue.shade900.withValues(alpha: 0.4),
          border: Colors.blue.shade700,
          onTap: _openPracticeLog,
        ),
        const SizedBox(width: 8),
        _chip('NEW STINT', color: Colors.grey.shade800, border: Colors.grey.shade600, onTap: _startNewStint),
      ],
    );
  }

  // --- race ---------------------------------------------------------------

  Widget _raceBody() {
    final telemetry = _state.telemetry;
    // No tyre picker in a race: the tyre comes from the HUD reading and
    // the compound shown next to our row during a pit stop.
    return Column(
      children: [
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
                      child: ShiftCard(gear: telemetry.gear, recentShifts: _state.recentShifts),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: TelemetryCard(label: 'PIT LAP', value: _pitLapDisplayValue(), alert: _pitLapAlert()),
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
    );
  }

  // --- time trial -----------------------------------------------------------

  /// Qualifying pace: best and last lap, the gap between them, and every
  /// recorded lap (best highlighted; swipe one away to delete it).
  Widget _timeTrialBody() {
    final laps = _state.timeTrialLaps;
    final best = TimeTrialLap.best(laps);
    final latest = laps.isEmpty ? null : laps.last;
    final delta = _state.sessionPhase == SessionPhase.driving ? _state.sectors.liveDeltaMs : null;
    final reference = _state.sectors.referenceLapMs;

    final bestSectors = SectorState.bestSectors(laps.map((l) => l.sectorsMs));
    final ideal = SectorState.idealLapMs(laps.map((l) => l.sectorsMs));

    Widget tile(String label, String value) => Expanded(
      child: TelemetryCard(label: label, value: value),
    );

    return Column(
      children: [
        SizedBox(
          height: 130,
          child: Row(
            children: [
              Expanded(
                child: TelemetryCard(
                  label: reference == null ? 'LIVE DELTA' : 'DELTA · REF ${TimeTrialLap.format(reference)}',
                  value: delta == null
                      ? '--'
                      : '${delta > 0
                            ? '+'
                            : delta < 0
                            ? '-'
                            : '±'}${(delta.abs() / 1000).toStringAsFixed(3)}',
                  baseColor: delta == null || delta.abs() < 5
                      ? Colors.white
                      : delta < 0
                      ? Colors.greenAccent
                      : Colors.redAccent,
                ),
              ),
              const SizedBox(width: 12),
              tile('BEST LAP', best == null ? '--' : TimeTrialLap.format(best.lapTimeMs)),
              const SizedBox(width: 12),
              tile('LAST LAP', latest == null ? '--' : TimeTrialLap.format(latest.lapTimeMs)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 110,
          child: Row(
            children: [
              if (!_state.sectors.mapped && bestSectors.every((b) => b == null))
                Expanded(
                  flex: 3,
                  child: _sectorNote(
                    _state.sessionPhase == SessionPhase.driving
                        ? 'SECTORS  ·  learning this circuit -- the next full lap sets the lines'
                        : 'SECTORS  ·  drive one full lap here and the sector lines are learned',
                  ),
                )
              else
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(child: _sectorCell(i, bestSectors[i], latest?.sectorsMs)),
                ],
              const SizedBox(width: 12),
              Expanded(
                child: TelemetryCard(label: 'IDEAL LAP', value: ideal == null ? '--' : TimeTrialLap.format(ideal)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                'LAPS  ·  swipe left to delete one',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.grey.shade400, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
            TextButton.icon(
              onPressed: _state.cornerReport == null ? null : _openCornerReport,
              icon: const Icon(Icons.turn_right, size: 18),
              label: const Text('CORNER REPORT'),
            ),
            if (laps.isNotEmpty) TextButton(onPressed: _confirmClearTimeTrial, child: const Text('CLEAR ALL')),
          ],
        ),
        Expanded(
          child: laps.isEmpty
              ? Center(
                  child: Text(
                    'Drive flying laps -- each completed lap is recorded here.',
                    style: TextStyle(color: Colors.grey.shade500),
                  ),
                )
              : ListView(
                  children: [
                    for (final (i, lap) in laps.indexed.toList().reversed)
                      Dismissible(
                        key: ValueKey(lap.recordedAt),
                        direction: DismissDirection.endToStart,
                        onDismissed: (_) => _raceStateManager.removeTimeTrialLap(lap.recordedAt),
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 16),
                          color: Colors.red.shade900,
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        child: ListTile(
                          dense: true,
                          leading: Text('L${i + 1}', style: TextStyle(color: Colors.grey.shade400)),
                          title: Text(
                            TimeTrialLap.format(lap.lapTimeMs),
                            style: TextStyle(
                              color: lap == best ? Colors.purpleAccent : Colors.white,
                              fontSize: 16,
                              fontWeight: lap == best ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                          subtitle: _lapSubtitle(lap, bestSectors),
                          trailing: Text(
                            lap == best ? 'BEST' : '+${((lap.lapTimeMs - best!.lapTimeMs) / 1000).toStringAsFixed(3)}s',
                            style: TextStyle(color: lap == best ? Colors.purpleAccent : Colors.grey.shade400),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  /// One sector of the lap in progress: this lap's time once it's done
  /// (purple if it's the best yet, else the gap to the best), the live
  /// sector highlighted, and the last lap's time (grey) until then.
  Widget _sectorCell(int i, int? best, List<int>? lastLap) {
    final sectors = _state.sectors;
    final live = sectors.mapped && _state.sessionPhase == SessionPhase.driving;
    final done = live && i < sectors.currentLapSplitsMs.length ? sectors.currentLapSplitsMs[i] : null;
    final current = live && i == sectors.currentSectorIndex && done == null;
    final shown = done ?? (lastLap != null && lastLap.length == 3 ? lastLap[i] : null);
    final isBest = done != null && (best == null || done <= best);
    final delta = done != null && best != null && !isBest ? (done - best) / 1000 : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: current ? Colors.white : Colors.grey.shade800, width: 2),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'S${i + 1}${current ? '  ·  NOW' : ''}',
            style: TextStyle(
              color: Colors.grey.shade400,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                shown == null ? '--' : SectorState.format(shown),
                style: TextStyle(
                  color: isBest ? Colors.purpleAccent : (done != null ? Colors.white : Colors.grey.shade600),
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          Text(
            delta != null
                ? '+${delta.toStringAsFixed(3)}s'
                : best == null
                ? ''
                : 'best ${SectorState.format(best)}',
            style: TextStyle(color: delta != null ? Colors.amberAccent : Colors.grey.shade500, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _sectorNote(String text) => Container(
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(
      color: Colors.grey.shade900,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.grey.shade800, width: 2),
    ),
    child: Text(
      text,
      style: TextStyle(color: Colors.grey.shade400, fontSize: 14, fontWeight: FontWeight.w600),
    ),
  );

  /// Tyre, then each sector (best ones purple).
  Widget _lapSubtitle(TimeTrialLap lap, List<int?> bestSectors) {
    final grey = TextStyle(color: Colors.grey.shade500);
    final sectors = lap.sectorsMs;
    return Text.rich(
      TextSpan(
        style: grey,
        children: [
          TextSpan(text: lap.tireCompound),
          if (sectors != null && sectors.length == 3)
            for (var i = 0; i < 3; i++)
              TextSpan(
                text: '   S${i + 1} ${SectorState.format(sectors[i])}',
                style: sectors[i] == bestSectors[i] ? const TextStyle(color: Colors.purpleAccent) : null,
              ),
        ],
      ),
      overflow: TextOverflow.ellipsis,
    );
  }

  Future<void> _confirmClearTimeTrial() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: const Text('Clear all time-trial laps?', style: TextStyle(color: Colors.white)),
        content: Text('This removes every recorded lap for this round.', style: TextStyle(color: Colors.grey.shade300)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) _raceStateManager.clearTimeTrialLaps();
  }

  // --- practice -----------------------------------------------------------

  /// The current stint's summary, or null if none (or a new stint has
  /// been started but no lap of it is done yet).
  StintSummary? _currentStintSummary() {
    final logger = _raceStateManager.practiceLapLogger;
    if (logger.currentStint == 0 || logger.newStintPending) return null;
    return StintSummary.fromLaps(_state.practiceLaps).where((s) => s.stintNumber == logger.currentStint).firstOrNull;
  }

  static String _lapTime(num? ms) {
    if (ms == null || ms <= 0) return '--';
    final minutes = ms ~/ 60000;
    return '$minutes:${((ms % 60000) / 1000).toStringAsFixed(3).padLeft(6, '0')}';
  }

  Widget _practiceBody() {
    final plan = _testPlan;
    final progress = plan == null || plan.stints.isEmpty ? null : _testPlanProgress(plan);
    final stint = _currentStintSummary();
    final logger = _raceStateManager.practiceLapLogger;
    final running = progress?.running;
    final wear = logger.currentTireWearPercent;
    final fuel = _state.sessionPhase == SessionPhase.offTrack ? null : _state.telemetry.fuelPercent;
    final expected = running == null ? null : progress!.expectedLaps[running.number - 1];
    final fuelPerLap = stint?.fuelPerLapPercent;
    final clean = stint?.laps.where((l) => !l.isPitLap).toList() ?? const [];
    final best = clean.isEmpty ? null : clean.map((l) => l.lapTimeMs).reduce((a, b) => a < b ? a : b);
    final dropOff = stint?.dropOffMs;

    Widget tile(String label, String value, {bool alert = false}) => Expanded(
      child: TelemetryCard(label: label, value: value, alert: alert),
    );

    return Column(
      children: [
        _practiceTestPanel(plan, progress, stint),
        const SizedBox(height: 12),
        Expanded(
          child: Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    tile(
                      'TYRES LEFT',
                      wear == null ? '--' : '${wear.toStringAsFixed(0)}%',
                      alert:
                          running?.kind == TestStintKind.long &&
                          wear != null &&
                          wear <= running!.stopAtWearRemainingPercent! + TestPlanTracker.wearTolerancePercent,
                    ),
                    const SizedBox(width: 12),
                    tile('LAPS', '${stint?.lapCount ?? 0}${expected == null ? '' : ' / ~$expected'}'),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  children: [
                    tile('FUEL', fuel == null || fuel <= 0 ? '--' : '${fuel.toStringAsFixed(0)}%'),
                    const SizedBox(width: 12),
                    tile('FUEL / LAP', fuelPerLap == null ? '--' : '${fuelPerLap.toStringAsFixed(2)}%'),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  children: [
                    tile('LAST LAP', _lapTime(_state.telemetry.lastLapTimeMs)),
                    const SizedBox(width: 12),
                    tile('BEST (STINT)', _lapTime(best)),
                    const SizedBox(width: 12),
                    tile(
                      'DROP-OFF',
                      dropOff == null ? '--' : '${dropOff >= 0 ? '+' : ''}${(dropOff / 1000).toStringAsFixed(2)}s',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _tyreRow(),
      ],
    );
  }

  /// The test plan, front and centre: the running test (or what's next),
  /// with buttons to start, choose or end a test. Turns green when the
  /// running test has hit its target.
  Widget _practiceTestPanel(TestPlan? plan, TestPlanProgress? progress, StintSummary? stint) {
    final TextStyle big = const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold);
    final TextStyle small = TextStyle(color: Colors.grey.shade300, fontSize: 13);

    if (plan == null || progress == null) {
      return _panel(Colors.grey.shade900, Colors.grey.shade700, [
        Text('NO TEST PLAN', style: big),
        const SizedBox(height: 4),
        Text('Save a round on the strategy screen (flag button) to get one.', style: small),
      ]);
    }

    final running = progress.running;
    final count = plan.stints.length;

    if (running != null) {
      return _panel(Colors.indigo.shade800, Colors.indigo.shade300, [
        Text('TEST ${running.number}/$count RUNNING', style: big),
        const SizedBox(height: 4),
        Text(progress.targetFor(running), style: small),
        Text(
          'Boxington calls it complete when the target is reached -- nothing to tap.',
          style: TextStyle(color: Colors.indigo.shade100, fontSize: 11),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _panelButton('END EARLY', () => _confirmEndTest(running)),
            const SizedBox(width: 8),
            _panelButton('CHOOSE TEST', () => _pickTest(plan)),
          ],
        ),
      ]);
    }

    final justDone = _justCompletedTest;
    final doneLine = justDone == null
        ? null
        : Text(
            'TEST ${justDone.number} COMPLETE \u2713',
            style: const TextStyle(color: Colors.greenAccent, fontSize: 14, fontWeight: FontWeight.bold),
          );

    final next = progress.next;
    if (next == null) {
      return _panel(Colors.green.shade900, Colors.green.shade400, [
        ?doneLine,
        Text('TEST PLAN COMPLETE', style: big),
        const SizedBox(height: 4),
        Text('All $count tests done -- see the practice log for the results.', style: small),
        const SizedBox(height: 10),
        Row(children: [_panelButton('RUN A TEST AGAIN', () => _pickTest(plan))]),
      ]);
    }

    return _panel(Colors.grey.shade900, justDone == null ? Colors.grey.shade600 : Colors.greenAccent, [
      ?doneLine,
      Text('NEXT: TEST ${next.number}/$count', style: big),
      const SizedBox(height: 4),
      Text(progress.targetFor(next), style: small),
      Text(next.purpose, style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
      const SizedBox(height: 10),
      Row(
        children: [
          _panelButton('START TEST', () => _confirmStartTest(next)),
          const SizedBox(width: 8),
          _panelButton('CHOOSE TEST', () => _pickTest(plan)),
        ],
      ),
    ]);
  }

  Widget _panel(Color colour, Color border, List<Widget> children) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: colour,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: border, width: 2),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
  );

  Widget _panelButton(String label, VoidCallback onPressed) => Expanded(
    child: ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.35),
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
    ),
  );
}
