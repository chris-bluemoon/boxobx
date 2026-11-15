import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import '../models/fused_race_state.dart';
import '../models/connection_status.dart';
import '../models/voice_engine_status.dart';
import '../widgets/voice_status_badge.dart';
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
import '../services/rejoin_coach.dart';
import '../services/saved_briefing_store.dart';
import '../services/league_roster.dart';
import '../services/race_rival_store.dart';
import '../models/shift_event.dart';
import '../models/opponent_pit_stop.dart';
import '../services/rejoin_forecaster.dart';
import '../services/pit_call_advisor.dart';
import '../services/test_plan_tracker.dart';
import '../services/stint_summary.dart';
import '../services/water_trend.dart';
import '../services/wet_tyre_caller.dart';
import '../services/race_report.dart';
import '../services/corner_report.dart';
import '../models/test_plan.dart';
import '../services/app_mode_store.dart';
import '../models/app_mode.dart';
import '../models/sector_state.dart';
import '../models/time_trial_lap.dart';
import '../models/race_strategy.dart';
import '../models/weather_forecast.dart';
import 'race_strategy_screen.dart';
import 'practice_log_screen.dart';
import 'aprl_standings_view.dart';
import '../services/tyre_best_laps.dart';
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

/// Section 6: Hyper-minimalist, high-contrast, dark mode dashboard.
class DashboardScreen extends StatefulWidget {
  /// Connect to the console and the laptop relay as soon as the
  /// dashboard opens. Off only in widget tests, which shouldn't open
  /// real network sockets.
  final bool connectOnStart;

  /// Integration tests only: a state manager to use (and feed frames to)
  /// in place of the dashboard's own.
  @visibleForTesting
  final FusedRaceStateManager? raceStateManager;

  const DashboardScreen({super.key, this.connectOnStart = true, this.raceStateManager});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late final FusedRaceStateManager _raceStateManager;
  late final VoiceEngine _voiceEngine;
  final _shiftCoachTrigger = ProactiveCoachTrigger();
  final _pitCallAdvisor = PitCallAdvisor();
  final _testPlanCaller = TestPlanCaller();
  final _dropOffCaller = TyreDropOffCaller();
  final _wetTyreCaller = WetTyreCaller();
  int _wetTyreCheckedLap = -1;
  int _dropOffCheckedLaps = -1;

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

  /// The bottom bar's tab: Home at every launch. Off the three mode tabs
  /// (Home, APRL) the connection stays up but unprompted calls are held.
  _Tab _tab = _Tab.home;

  bool get _choosingMode => _tab == _Tab.home || _tab == _Tab.aprl;

  static _Tab _tabFor(AppMode mode) => switch (mode) {
    AppMode.race => _Tab.race,
    AppMode.practice => _Tab.practice,
    AppMode.timeTrial => _Tab.timeTrial,
  };

  /// Practice with the test plan folded to one line: free practice. A
  /// running test always shows in full.
  bool _planHidden = false;

  void _setPlanHidden(bool hidden) {
    setState(() => _planHidden = hidden);
    AppModeStore.savePlanHidden(hidden);
  }

  Future<void> _loadMode() async {
    final mode = await AppModeStore.load();
    final planHidden = await AppModeStore.loadPlanHidden();
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _planHidden = planHidden;
    });
    _raceStateManager.setMode(mode);
  }

  void _setMode(AppMode mode) {
    setState(() => _tab = _tabFor(mode));
    if (mode == _mode) return;
    setState(() => _mode = mode);
    _raceStateManager.setMode(mode);
    AppModeStore.save(mode);
    // Nothing queued in one mode should be spoken in the other.
    _voiceEngine.clearQueuedCallouts();
  }

  FusedRaceState _state = FusedRaceState.initial();

  /// Boxington's voice pipeline, a dot in the Race Mode heading.
  VoiceEngineStatus _voiceStatus = VoiceEngineStatus.idle;

  ConnectionStatus _telemetryStatus = ConnectionStatus.disconnected;
  ConnectionStatus _hudStatus = ConnectionStatus.disconnected;

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

  /// Boxington's drop-off call (Practice Mode, outside a test -- a test
  /// stint's own call covers it): the current stint's tyres have gone
  /// off. Checked once per new lap.
  void _maybeMakeDropOffCall(FusedRaceState state) {
    if (!_mode.testPlan || _choosingMode) return;
    if (state.practiceLaps.length == _dropOffCheckedLaps) return;
    _dropOffCheckedLaps = state.practiceLaps.length;
    if (_raceStateManager.practiceLapLogger.activeTestNumber != null) return;
    final prompt = _dropOffCaller.check(_currentStintSummary());
    if (prompt != null) _voiceEngine.speakProactively(prompt, state);
  }

  /// Race Mode, wet race: once a lap, whether to change tyres for the
  /// weather (see WetTyreCaller) -- needs the round's weather brief.
  void _maybeMakeWetTyreCall(FusedRaceState state) {
    final forecast = state.weather;
    final totalLaps = state.raceLaps?.total;
    final water = state.hud.waterPercent;
    if (_choosingMode || state.sessionPhase != SessionPhase.driving) return;
    final lap = state.telemetry.currentLap;
    if (lap == _wetTyreCheckedLap) return;

    // Practice: what the gauge says, as information.
    if (_mode == AppMode.practice) {
      if (water == null) return;
      _wetTyreCheckedLap = lap;
      final prompt = _wetTyreCaller.practiceCheck(
        water: water,
        currentCompound: _raceStateManager.practiceLapLogger.currentTireCompound,
        laps: state.practiceLaps,
      );
      if (prompt != null) _voiceEngine.speakProactively(prompt, state);
      return;
    }

    if ((forecast == null && water == null) || totalLaps == null || !_mode.pitCalls) return;
    _wetTyreCheckedLap = lap;
    final prompt = _wetTyreCaller.check(
      forecast: forecast,
      currentLap: lap,
      totalLaps: totalLaps,
      currentCompound: _raceStateManager.practiceLapLogger.currentTireCompound,
      laps: state.practiceLaps,
      pitLossSeconds: state.pitStopTimeSeconds ?? FusedRaceState.assumedPitStopSeconds,
      pitLossAssumed: state.pitStopTimeSeconds == null,
      plannedStopLaps: [for (final s in _plannedStops) s.lap],
      opponentStops: state.opponentPitStops,
      waterPercent: water,
      waterPercentPerMinute: state.waterPercentPerMinute,
      lapSeconds: state.telemetry.lastLapTimeMs > 0 ? state.telemetry.lastLapTimeMs / 1000 : null,
      radar: state.hud.radar,
    );
    if (prompt != null) _voiceEngine.speakProactively(prompt, state);
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

  /// "Wait... wait... GO" after a spin or an off (see RejoinCoach).
  final _rejoinCoach = RejoinCoach();

  static const _rejoinWords = {RejoinCall.wait: 'Wait.', RejoinCall.go: 'Go! Go! Go!'};

  void _maybeMakeRejoinCall(FusedRaceState state) {
    final onTrack = state.sessionPhase == SessionPhase.driving || state.sessionPhase == SessionPhase.unknown;
    if (!_mode.incidentCalls || _choosingMode || !onTrack) return;
    final call = _rejoinCoach.update(
      speedKmh: state.telemetry.speedKmh,
      inPitLane: state.hud.playerInPit,
      traffic: state.hud.traffic,
      now: DateTime.now(),
      raceOver: state.raceLaps != null && state.telemetry.currentLap > state.raceLaps!.total,
    );
    if (call != null) _voiceEngine.speakClip(_rejoinWords[call]!);
  }

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
        title: Text('Start stint test ${test.number}?', style: const TextStyle(color: Colors.white)),
        content: Text(
          '${_testPlanProgress(_testPlan!).targetFor(test)}\n\nYour next lap starts this stint test. Fit ${test.compoundShort}s with '
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
        title: Text('End stint test ${test.number}?', style: const TextStyle(color: Colors.white)),
        content: Text(
          'Your next lap starts a normal stint. The stint test only counts if it reached its target.',
          style: TextStyle(color: Colors.grey.shade300),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('End stint test')),
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
                  'Stint Test ${test.number}: ${progress.targetFor(test)}',
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

  static IconData _modeIcon(AppMode mode) => switch (mode) {
    AppMode.race => Icons.sports_score,
    AppMode.practice => Icons.directions_car,
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

  /// The Home tab: the round, the best lap on each tyre so far, the
  /// saved race strategy in short, and the round's records.
  Widget _homePage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: BoxBoxLogo(size: 40, tagline: 'YOUR GT7 ENGINEER'),
        ),
        const SizedBox(height: 16),
        _trackHeader(accent: Colors.blueGrey.shade600, large: true, onTap: _pickRound),
        const SizedBox(height: 16),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              final cards = [_bestLapsCard(), _strategySummaryCard()];
              return wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [Expanded(child: cards[0]), const SizedBox(width: 16), Expanded(child: cards[1])],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [Expanded(child: cards[0]), const SizedBox(height: 16), Expanded(child: cards[1])],
                    );
            },
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            _homeButton(Icons.flag, 'RACE STRATEGY', _openRaceStrategy),
            const SizedBox(width: 12),
            _homeButton(Icons.list_alt, 'PRACTICE LOG', _openPracticeLog),
            const SizedBox(width: 12),
            _homeButton(
              Icons.assessment,
              'RACE REPORTS (${RaceReport.fromLaps(_state.practiceLaps).length})',
              _openRaceReports,
            ),
          ],
        ),
      ],
    );
  }

  /// A Home card: a heading and its content, tappable to open the page
  /// behind it.
  Widget _homeCard({required IconData icon, required String title, required Widget child, VoidCallback? onTap}) {
    return Material(
      color: Colors.grey.shade900,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: Colors.white70, size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 1.5),
                    ),
                  ),
                  if (onTap != null) const Icon(Icons.chevron_right, color: Colors.white54),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }

  /// Best (and average) clean dry lap on each tyre, practice and races
  /// together, with the time-trial best beside it.
  Widget _bestLapsCard() {
    final tyres = TyreBestLap.fromLaps(_state.practiceLaps, timeTrial: _state.timeTrialLaps);
    String time(num? ms) => ms == null ? '--' : TimeTrialLap.format(ms);
    const head = TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1);
    final quickest = tyres.isEmpty ? null : tyres.first.quickestMs;
    return _homeCard(
      icon: Icons.timer,
      title: 'BEST LAPS BY TYRE',
      onTap: _openPracticeLog,
      child: tyres.isEmpty
          ? Text(
              'No laps yet. Drive in Practice, a race or a time trial and each tyre\'s best lap shows here.',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 16),
            )
          : ListView(
              children: [
                const Row(
                  children: [
                    Expanded(flex: 3, child: Text('TYRE', style: head)),
                    Expanded(flex: 3, child: Text('BEST', style: head, textAlign: TextAlign.right)),
                    Expanded(flex: 3, child: Text('AVERAGE', style: head, textAlign: TextAlign.right)),
                    Expanded(flex: 3, child: Text('TIME TRIAL', style: head, textAlign: TextAlign.right)),
                  ],
                ),
                const SizedBox(height: 6),
                for (final t in tyres)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  switch (t.compound) {
                                    'Intermediate' => 'Inters',
                                    'Heavy Wet' => 'Wets',
                                    final c => c.replaceFirst('Racing ', ''),
                                  },
                                  maxLines: 1,
                                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                                ),
                              ),
                              Text(
                                t.laps == 0 ? 'time trial only' : '${t.laps} clean lap${t.laps == 1 ? '' : 's'}',
                                style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(
                            time(t.bestMs),
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: t.bestMs != null && t.bestMs == quickest ? Colors.purpleAccent.shade100 : Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(
                            time(t.averageMs),
                            textAlign: TextAlign.right,
                            style: TextStyle(color: Colors.grey.shade300, fontSize: 18),
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(
                            time(t.timeTrialMs),
                            textAlign: TextAlign.right,
                            style: TextStyle(color: Colors.deepPurple.shade100, fontSize: 18),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  /// The saved race strategy in short: start tyre, each stop, the
  /// summary.
  Widget _strategySummaryCard() {
    final strategy = _savedStrategy;
    String short(String compound) => compound.replaceFirst('Racing ', '');
    const big = TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold);
    return _homeCard(
      icon: Icons.flag,
      title: 'RACE STRATEGY',
      onTap: _openRaceStrategy,
      child: strategy == null
          ? Text(
              'No strategy yet. Open Race Strategy to brief the round and plan the stops.',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 16),
            )
          : ListView(
              children: [
                Text(
                  strategy.pitStops.isEmpty
                      ? 'NO STOP'
                      : '${strategy.pitStops.length}-STOP',
                  style: TextStyle(color: Colors.amber.shade300, fontSize: 15, fontWeight: FontWeight.w900, letterSpacing: 1.5),
                ),
                const SizedBox(height: 8),
                Text('Start on ${short(strategy.startingTireCompound)}', style: big),
                for (final stop in strategy.pitStops)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('Lap ${stop.lap}: Box for ${short(stop.tireCompound)}', style: big),
                  ),
                const SizedBox(height: 10),
                if (strategy.summary.isNotEmpty)
                  Text(
                    strategy.summary,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.grey.shade300, fontSize: 15),
                  ),
                const SizedBox(height: 8),
                Text(
                  'Fuel ${strategy.assumedPercentPerLap.toStringAsFixed(1)}%/lap · '
                  '${strategy.totalEstimatedTimeLossSeconds.toStringAsFixed(0)} s in the pits',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
                ),
              ],
            ),
    );
  }

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
        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
      ),
    );
  }

  /// Synthetic prompt for Boxington when other drivers enter the pits.
  /// Championship rivals (those the relay tracks positions for) are
  /// flagged so he can treat them as the priority.
  String _opponentPitCalloutPrompt(List<OpponentPitStop> stops) {
    final rival = _raceStateManager.raceRivalTracker.rival;
    final descriptions = stops
        .map((s) {
          final details = [
            if (s.position != null) 'P${s.position}',
            if (OpponentPitStop.tyreName(s.tyre) != null) 'fitting ${OpponentPitStop.tyreName(s.tyre)}',
            if (s.fuel != null) 'taking ${s.fuel} fuel',
          ];
          final who = s.driver == rival ? 'our RACE RIVAL ${s.driver}' : s.driver;
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

    _raceStateManager = widget.raceStateManager ?? FusedRaceStateManager(
      telemetryService: TelemetryUdpService(),
      hudService: HudOcrService(),
      sectorCalculator: SectorCalculator(),
      fuelPredictor: FuelPredictor(),
    );

    _loadActiveRoundName();
    _loadMode();
    _loadRaceRival();
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
    // Rejoin words play instantly from cache (no AI or TTS round trip).
    if (widget.connectOnStart) _voiceEngine.precacheClips(_rejoinWords.values);

    _raceStateManager.stream.listen((state) {
      if (!mounted) return;
      _trackPositionLoss(state.hud.gridPosition);
      setState(() => _state = state);
      _maybeAutoFillTireCompoundFromOcr(state);
      _maybeMakePitCall(state);
      _maybeMakeTestPlanCall(state);
      _maybeMakeDropOffCall(state);
      _maybeMakeWetTyreCall(state);
      _maybeMakeCornerCall(state);
      _maybeMakeRejoinCall(state);
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

    _raceStateManager.rivalEvents.listen((event) {
      if (!_mode.rivalCallouts || _choosingMode) return;
      _voiceEngine.speakProactively(event.prompt, _state);
    });

    _raceStateManager.crashes.listen((crash) {
      if (!_mode.incidentCalls || _choosingMode) return;
      _voiceEngine.speakProactively(crash.toPrompt(), _state);
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
    _raceStateManager.setWeather(briefing?.weather);
    _raceStateManager.setRound(name);
    _raceStateManager.setRaceLength(minutes: briefing?.raceLengthMinutes, plannedLaps: briefing?.totalLaps);
    setState(() {
      _activeRoundName = name;
      // The round's track: as briefed, else as the calendar has it -- so
      // every mode follows the round picked on the home page.
      _activeTrackName = briefing?.trackName ?? (name == null ? null : LeagueCalendar.byName(name)?.gt7Track);
    });
  }

  /// The GT7 track of the current round (all three modes), from its
  /// briefing or the league calendar.
  String? _activeTrackName;

  /// The home page header's round picker: every round in the league
  /// calendar, plus any other round a briefing was saved under. Picking
  /// one makes it the current round for every mode -- its track, its
  /// briefing and strategy (if saved), its test plan and its laps.
  Future<void> _pickRound() async {
    final saved = await SavedBriefingStore.savedRounds();
    if (!mounted) return;
    final calendarNames = {for (final r in LeagueCalendar.rounds) r.name};
    final custom = [for (final name in saved) if (name.isNotEmpty && !calendarNames.contains(name)) name];
    final briefed = saved.toSet();
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Round · ${LeagueCalendar.season}'),
        children: [
          for (final round in LeagueCalendar.rounds)
            _roundOption(context, round.name, '${round.circuit} · ${round.details}', briefed.contains(round.name)),
          for (final name in custom) _roundOption(context, name, 'Custom round', true),
        ],
      ),
    );
    if (picked == null || !mounted || picked == _activeRoundName) return;
    await SavedBriefingStore.selectRound(picked);
    await _loadActiveRoundName();
  }

  Widget _roundOption(BuildContext context, String name, String details, bool briefed) {
    final current = name == _activeRoundName;
    final round = LeagueCalendar.byName(name);
    return SimpleDialogOption(
      onPressed: () => Navigator.pop(context, name),
      child: Row(
        children: [
          Icon(current ? Icons.radio_button_checked : Icons.radio_button_off, color: current ? Colors.white : Colors.grey, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  round?.round ?? name,
                  style: TextStyle(fontWeight: current ? FontWeight.bold : FontWeight.w600, fontSize: 16),
                ),
                Text(details, style: TextStyle(color: Colors.grey.shade400, fontSize: 14)),
              ],
            ),
          ),
          if (briefed) Text('BRIEFED', style: TextStyle(color: Colors.green.shade300, fontSize: 13, letterSpacing: 1)),
        ],
      ),
    );
  }

  /// Circuit outlines for the header emblems (loaded once at start).
  TrackOutlines? _trackOutlines;

  /// The page heading: round, circuit emblem and the page's own title.
  Widget _trackHeader({
    required Color accent,
    String? pageTitle,
    IconData? pageIcon,
    VoidCallback? onPageTitleTap,
    bool large = false,
    VoidCallback? onTap,
    List<Widget> statusDots = const [],
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
      onTap: onTap,
      statusDots: statusDots,
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
          weather: _state.weather,
          pitStopTimeSeconds: _state.pitStopTimeSeconds,
          onClear: () {
            _raceStateManager.clearPracticeLaps();
            Navigator.of(context).pop();
          },
          onDeleteLap: (recordedAt) => _raceStateManager.removePracticeLap(recordedAt),
          onDeleteStint: (recordedAts) => _raceStateManager.removePracticeLaps(recordedAts),
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

  /// Dashboard-owned per-session state, reset automatically when GT7
  /// reports leaving the track (FusedRaceStateManager.sessionEnded).
  void _resetSessionTracking() {
    _shiftCoachTrigger.reset();
    // Clears tracked rival positions too -- otherwise a rival's LAST
    // position from a previous race would be compared against this
    // new session's first reading and fire a spurious "rival moved"
    // callout purely from the session boundary, not a real on-track
    // change.
    _pitCallAdvisor.reset();
    _testPlanCaller.reset();
    _dropOffCaller.reset();
    _wetTyreCaller.reset();
    _rejoinCoach.reset();
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: switch (_tab) {
            _Tab.home => _homePage(),
            _Tab.aprl => const AprlStandingsView(),
            _ => _modePage(),
          },
        ),
      ),
      bottomNavigationBar: _bottomBar(),
    );
  }

  /// Home, the three modes, and the league.
  Widget _bottomBar() {
    final accent = switch (_tab) {
      _Tab.home => Colors.blueGrey.shade600,
      _Tab.race => _modeColour(AppMode.race),
      _Tab.practice => _modeColour(AppMode.practice),
      _Tab.timeTrial => _modeColour(AppMode.timeTrial),
      _Tab.aprl => Colors.amber.shade800,
    };
    // Lighter than the black pages, with a top edge in the tab's colour,
    // so the bar stands apart from the page above it.
    final bar = NavigationBarTheme(
      data: NavigationBarThemeData(
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            color: states.contains(WidgetState.selected) ? Colors.white : Colors.grey.shade400,
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? Colors.white : Colors.grey.shade400,
            size: 28,
          ),
        ),
      ),
      child: NavigationBar(
        backgroundColor: const Color(0xFF2E2E3A),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 84,
        indicatorColor: accent,
        selectedIndex: _tab.index,
        onDestinationSelected: (i) {
          final tab = _Tab.values[i];
          switch (tab) {
            case _Tab.race:
              _setMode(AppMode.race);
            case _Tab.practice:
              _setMode(AppMode.practice);
            case _Tab.timeTrial:
              _setMode(AppMode.timeTrial);
            case _Tab.home || _Tab.aprl:
              setState(() => _tab = tab);
          }
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home), label: 'HOME'),
          NavigationDestination(icon: Icon(Icons.sports_score), label: 'RACE MODE'),
          NavigationDestination(icon: Icon(Icons.directions_car), label: 'PRACTICE'),
          NavigationDestination(icon: Icon(Icons.timer), label: 'TIME TRIAL'),
          NavigationDestination(icon: Icon(Icons.emoji_events), label: 'APRL'),
        ],
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(height: 4, color: accent),
        bar,
      ],
    );
  }

  /// The current mode's page: header (with the connection dots), status
  /// chips and the mode's own body.
  Widget _modePage() {
    return Column(
      children: [
        _trackHeader(
          accent: _modeColour(_mode),
          pageTitle: _mode.label,
          pageIcon: _modeIcon(_mode),
          statusDots: [
            StatusBadge(label: 'TELEMETRY', status: _telemetryStatus, dotOnly: true),
            StatusBadge(label: 'HUD OCR', status: _hudStatus, dotOnly: true),
            // Boxington only talks back in a race (listening, thinking, errors).
            if (_mode == AppMode.race) VoiceStatusBadge(status: _voiceStatus, dotOnly: true),
          ],
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
      ],
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
        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
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
        if (_mode.rivalCallouts) _rivalChip(),
      ],
    );
  }

  /// The race rival: who, and where they are; tap to choose.
  Widget _rivalChip() {
    final rival = _raceStateManager.raceRivalTracker.rival;
    if (rival == null) {
      return _chip('PICK RIVAL', color: Colors.grey.shade800, border: Colors.amber.shade700, onTap: _pickRival);
    }
    final state = _state.raceRival;
    final gap = state?.gapSeconds;
    final parts = [
      'RIVAL: $rival',
      if (state?.position != null) 'P${state!.position}',
      if (gap != null) '${gap >= 0 ? '+' : '-'}${gap.abs().toStringAsFixed(1)}s',
      if (state?.inPit ?? false) 'PIT',
      if (state?.inTrouble ?? false) 'STOPPED',
    ];
    return _chip(
      parts.join(' · '),
      color: Colors.amber.shade900.withValues(alpha: 0.4),
      border: Colors.amber.shade700,
      onTap: _pickRival,
    );
  }

  Future<void> _pickRival() async {
    final current = _raceStateManager.raceRivalTracker.rival;
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Race rival'),
        children: [
          for (final name in leagueRoster)
            if (name != playerName)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, name),
              child: Text(name, style: TextStyle(fontWeight: name == current ? FontWeight.bold : FontWeight.normal)),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('No rival', style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final rival = picked.isEmpty ? null : picked;
    setState(() => _raceStateManager.setRaceRival(rival));
    RaceRivalStore.save(rival);
  }

  Future<void> _loadRaceRival() async {
    final rival = await RaceRivalStore.load();
    if (!mounted || rival == null || rival == playerName) return;
    setState(() => _raceStateManager.setRaceRival(rival));
  }

  /// Practice's tyre row: the tyre laps are being logged on,
  /// read-only (the relay reads it off the HUD, and starting a test sets
  /// it), plus the laps chip and NEW STINT.
  Widget _tyreRow() {
    return Row(
      children: [
        const Text(
          'TIRE:',
          style: TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.bold),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _selectedTireCompound,
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(width: 8),
        _weatherChip(),
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

  /// Practice's weather chip: the GT7 weather the laps are being
  /// tested in (set the same in the practice lobby), for wet testing.
  /// " ↑" / " ↓" when the water gauge is clearly rising or falling.
  String _waterArrow() {
    final rate = _state.waterPercentPerMinute;
    if (rate == null || rate.abs() < WaterTrend.steadyPercentPerMinute) return '';
    return rate > 0 ? ' ↑' : ' ↓';
  }

  Widget _weatherChip() {
    final weather = _raceStateManager.practiceLapLogger.currentWeather;
    return _chip(
      'WEATHER: ${weather ?? 'DRY'}${_state.hud.waterPercent == null ? '' : ' · WATER ${_state.hud.waterPercent!.round()}%${_waterArrow()}'} ▾',
      color: weather == null ? Colors.amber.shade900.withValues(alpha: 0.35) : const Color(0xFF0D47A1),
      border: weather == null ? Colors.amber.shade700 : Colors.lightBlue.shade400,
      onTap: _pickWeather,
    );
  }

  /// Picks the weather being tested: dry or a rain preset, with the
  /// presets in the round's weather brief marked. A change starts a new
  /// stint, so each stint is one weather.
  Future<void> _pickWeather() async {
    final inBrief = {...?_state.weather?.slots.where((s) => s.isRain).map((s) => s.code)};
    final current = _raceStateManager.practiceLapLogger.currentWeather;
    Widget option(String? code, String name, String tyre) => SimpleDialogOption(
      onPressed: () => Navigator.pop(context, code ?? 'DRY'),
      child: Row(
        children: [
          Icon(code == current ? Icons.radio_button_checked : Icons.radio_button_off, size: 20, color: code == current ? Colors.white : Colors.grey),
          const SizedBox(width: 12),
          SizedBox(width: 44, child: Text(code ?? 'DRY', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontSize: 14)),
                Text(tyre, style: TextStyle(color: Colors.grey.shade400, fontSize: 14)),
              ],
            ),
          ),
          if (code != null && inBrief.contains(code)) Text('IN BRIEF', style: TextStyle(color: Colors.lightBlue.shade200, fontSize: 13, letterSpacing: 1)),
        ],
      ),
    );
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Weather being tested'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'Set the same weather in the practice lobby. Changing it starts a new stint.',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
            ),
          ),
          option(null, 'Dry (cloudy or sunny)', 'Slicks'),
          for (var n = 1; n <= 8; n++)
            if (WeatherSlot('R0$n') case final slot) option(slot.code, slot.name, slot.tyre.label),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _raceStateManager.practiceLapLogger.setWeather(picked == 'DRY' ? null : picked));
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
                style: TextStyle(color: Colors.grey.shade400, fontSize: 14, fontWeight: FontWeight.w600),
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
            style: TextStyle(color: delta != null ? Colors.amberAccent : Colors.grey.shade500, fontSize: 16),
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
    final best = stint?.bestLapMs;
    final dropOff = stint?.dropOffMs;
    final wentOff = stint?.tyreDropOff != null;

    Widget tile(String label, String value, {bool alert = false}) => Expanded(
      child: TelemetryCard(label: label, value: value, alert: alert),
    );

    return Column(
      children: [
        if (_planHidden && progress?.running == null) _hiddenPlanBar(progress) else _practiceTestPanel(plan, progress, stint),
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
                    tile(
                      (stint?.excludedLaps.length ?? 0) == 0 ? 'LAPS' : 'LAPS (+${stint!.excludedLaps.length} OFF-PACE)',
                      '${stint?.lapCount ?? 0}${expected == null ? '' : ' / ~$expected'}',
                    ),
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
                      wentOff ? 'DROPPED OFF' : 'DROP-OFF',
                      dropOff == null ? '--' : '${dropOff >= 0 ? '+' : ''}${(dropOff / 1000).toStringAsFixed(2)}s',
                      alert: wentOff,
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
        Text('NO STINT TESTS', style: big),
        const SizedBox(height: 4),
        Text('Save a round on the strategy screen (flag button) to get one.', style: small),
        const SizedBox(height: 10),
        Row(children: [_panelButton('HIDE', () => _setPlanHidden(true))]),
      ]);
    }

    final running = progress.running;
    final count = plan.stints.length;

    if (running != null) {
      return _panel(Colors.indigo.shade800, Colors.indigo.shade300, [
        Text('STINT TEST ${running.number}/$count RUNNING', style: big),
        const SizedBox(height: 4),
        Text(progress.targetFor(running), style: small),
        Text(
          'Boxington calls it complete when the target is reached -- nothing to tap.',
          style: TextStyle(color: Colors.indigo.shade100, fontSize: 13),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _panelButton('END EARLY', () => _confirmEndTest(running)),
          ],
        ),
      ]);
    }

    final justDone = _justCompletedTest;
    final doneLine = justDone == null
        ? null
        : Text(
            'STINT TEST ${justDone.number} COMPLETE \u2713',
            style: const TextStyle(color: Colors.greenAccent, fontSize: 14, fontWeight: FontWeight.bold),
          );

    final next = progress.next;
    if (next == null) {
      return _panel(Colors.green.shade900, Colors.green.shade400, [
        ?doneLine,
        Text('STINT TESTS COMPLETE', style: big),
        const SizedBox(height: 4),
        Text('All $count stint tests done -- see the practice log for the results.', style: small),
        const SizedBox(height: 10),
        Row(
          children: [
            _panelButton('RUN ONE AGAIN', () => _pickTest(plan)),
            const SizedBox(width: 8),
            _panelButton('HIDE', () => _setPlanHidden(true)),
          ],
        ),
      ]);
    }

    return _panel(Colors.grey.shade900, justDone == null ? Colors.grey.shade600 : Colors.greenAccent, [
      ?doneLine,
      Text('NEXT: STINT TEST ${next.number}/$count', style: big),
      const SizedBox(height: 4),
      Text(progress.targetFor(next), style: small),
      Text(next.purpose, style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
      const SizedBox(height: 10),
      Row(
        children: [
          _panelButton('START', () => _confirmStartTest(next)),
          const SizedBox(width: 8),
          _panelButton('CHOOSE STINT TEST', () => _pickTest(plan)),
          const SizedBox(width: 8),
          _panelButton('HIDE', () => _setPlanHidden(true)),
        ],
      ),
    ]);
  }

  /// The test plan folded away: one line, to bring it back.
  Widget _hiddenPlanBar(TestPlanProgress? progress) {
    final next = progress?.next;
    final status = progress == null
        ? 'no stint tests'
        : next == null
        ? 'stint tests complete'
        : 'next: stint test ${next.number}/${progress.plan.stints.length}: ${progress.targetFor(next)}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade800),
      ),
      child: Row(
        children: [
          const Text('FREE PRACTICE', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(status, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
          ),
          TextButton(onPressed: () => _setPlanHidden(false), child: const Text('SHOW STINT TESTS')),
        ],
      ),
    );
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

/// The bottom bar's tabs, in order.
enum _Tab { home, race, practice, timeTrial, aprl }
