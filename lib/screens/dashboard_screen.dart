import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import '../models/fused_race_state.dart';
import '../models/connection_status.dart';
import '../models/voice_engine_status.dart';
import '../widgets/voice_status_badge.dart';
import '../services/driver_profile.dart';
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
import '../services/corner_report.dart';
import '../models/test_plan.dart';
import '../services/app_mode_store.dart';
import '../models/app_mode.dart';
import '../models/sector_state.dart';
import '../models/time_trial_lap.dart';
import '../models/race_strategy.dart';
import 'race_strategy_screen.dart';
import 'practice_log_screen.dart';
import 'practice_rounds_screen.dart';
import 'aprl_standings_view.dart';
import '../services/tyre_best_laps.dart';
import 'race_rounds_screen.dart';
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

  /// Why Boxington can't speak (see VoiceEngine.problem), shown as a
  /// banner on every page; null when he can.
  String? _voiceProblem;
  Timer? _voiceRecheck;

  /// "BOXINGTON OFFLINE" across the top of every page while the voice
  /// can't reach its services -- tap to check again.
  Widget _voiceProblemBanner(String problem) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Material(
      color: Colors.red.shade900,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _voiceEngine.checkConnection,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.voice_over_off, color: Colors.white, size: 26),
              const SizedBox(width: 12),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: 'BOXINGTON OFFLINE  ', style: TextStyle(fontWeight: FontWeight.bold)),
                      TextSpan(text: problem),
                    ],
                  ),
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
              Text('TAP TO RETRY', style: TextStyle(color: Colors.red.shade100, fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    ),
  );

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

  static const List<String> _tireCompoundOptions = [
    'Racing Hard',
    'Racing Medium',
    'Racing Soft',
    'Intermediate',
    'Heavy Wet',
  ];


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
      _raceStateManager.practiceLapLogger.setWeather(null);
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
          '${_testPlanProgress(_testPlan!).targetFor(test)}\n\n'
          '${test.weather == null ? '' : 'Set the lobby weather to ${test.weatherName}. '}'
          'Your next lap starts this stint test. Fit ${test.compoundShort.endsWith('s') ? test.compoundShort : '${test.compoundShort}s'} with '
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
    // The test's weather (a wet test's rain preset; dry otherwise) goes on
    // its laps -- no weather to pick.
    _raceStateManager.practiceLapLogger.setWeather(test.weather);
    _raceStateManager.startTestStint(test.number, throughStops: test.kind == TestStintKind.race);
    _testPlanCaller.reset();
    if (_tireCompoundOptions.contains(test.compound)) {
      _raceStateManager.setPracticeTireCompound(test.compound);
    }
    setState(() {});
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
      _raceStateManager.practiceLapLogger.setWeather(null);
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
        builder: (_) => RaceRoundsScreen(
          currentRound: _activeRoundName ?? '',
          currentLaps: () => _state.practiceLaps,
          currentStrategy: _savedStrategy,
          currentTimeTrialBest: TimeTrialLap.best(_state.timeTrialLaps),
          deleteCurrentLaps: _raceStateManager.removePracticeLaps,
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
        // The splash page's wordmark: tyres for the O's.
        const Align(
          alignment: Alignment.centerLeft,
          child: BoxBoxWheelWordmark(size: 52, tagline: 'YOUR GT7 ENGINEER'),
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
            _homeButton(Icons.flag, 'RACE BRIEF', _openRaceStrategy),
            const SizedBox(width: 12),
            _homeButton(Icons.list_alt, 'PRACTICE LOG', _openPracticeRounds),
            const SizedBox(width: 12),
            _homeButton(Icons.assessment, 'RACE REPORTS', _openRaceReports),
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
      onTap: _openPracticeRounds,
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
      title: 'RACE BRIEF',
      onTap: _openRaceStrategy,
      child: strategy == null
          ? Text(
              'No strategy yet. Open the Race Brief to brief the round and plan the stops.',
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
                Text('Start on ${short(strategy.startingTireCompound)}${strategy.validatedByPractice ? '' : ' ★'}', style: big),
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
                if (!strategy.validatedByPractice) ...[
                  const SizedBox(height: 8),
                  Text(
                    RaceStrategyScreen.notValidatedNote(strategy),
                    style: TextStyle(color: Colors.amber.shade300, fontSize: 14),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  '${strategy.fuelMap > 1 ? 'Fuel Map ${strategy.fuelMap} · ' : ''}'
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

    // Can Boxington reach Groq from this network? Checked now, so a
    // blocked network shows before the race -- and again every 30s
    // while he can't, so the banner clears once it's sorted.
    _voiceEngine.problems.listen((problem) {
      if (mounted) setState(() => _voiceProblem = problem);
    });
    if (widget.connectOnStart) {
      _voiceEngine.checkConnection();
      _voiceRecheck = Timer.periodic(const Duration(seconds: 30), (_) {
        if (_voiceEngine.problem != null) _voiceEngine.checkConnection();
      });
    }

    _raceStateManager.stream.listen((state) {
      if (!mounted) return;
      _trackPositionLoss(state.hud.gridPosition);
      setState(() => _state = state);
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
    _raceStateManager.sessionEnded.listen((_) {
      _resetSessionTracking();
      _refreshDriverProfile();
    });
    _refreshDriverProfile();

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

    _raceStateManager.spins.listen((event) {
      if (!DriverProfile.boxingtonUsesIt || !_mode.incidentCalls || _choosingMode) return;
      final (spin, corner) = event;
      _voiceEngine.speakProactively(spin.toPrompt(corner: corner), _state);
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

  /// The Practice Log's list of rounds with stints (Home); the current
  /// round opens with its live laps.
  Future<void> _openPracticeRounds() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PracticeRoundsScreen(
          currentRound: _activeRoundName ?? '',
          currentLaps: () => _state.practiceLaps,
          openCurrentRound: _openPracticeLog,
        ),
      ),
    );
  }

  /// The current round's log (straight from the Practice screen).
  Future<void> _openPracticeLog() async {
    await Navigator.of(context).push(
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
    await RaceStrategyScreen.lastSave; // the brief saves itself as it's edited
    _loadActiveRoundName();
  }

  /// Dashboard-owned per-session state, reset automatically when GT7
  /// reports leaving the track (FusedRaceStateManager.sessionEnded).
  /// What Boxington knows about the driver, from every round's laps (see
  /// DriverProfile) -- rebuilt at start and after each session, so the
  /// last race is in it.
  Future<void> _refreshDriverProfile() async {
    if (!DriverProfile.boxingtonUsesIt) return;
    try {
      final profile = await DriverProfile.load();
      _voiceEngine.groqService.driverProfile = profile.isEmpty ? null : profile.toPrompt();
    } catch (error) {
      debugPrint('Driver profile not loaded: $error');
    }
  }

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
    _voiceRecheck?.cancel();
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
  /// directly on GT7's own HUD. Race Mode: the strategy's next stop (or
  /// sooner, when the fuel runs out first -- see NextPitLap); NONE when
  /// no stop is left. Practice: the lap the fuel runs out.
  String _pitLapDisplayValue() {
    if (_mode == AppMode.race) {
      final next = _nextPitLap();
      if (next != null) return 'L${next.lap}';
      final known = _state.fuelPrediction.hasEnoughData || _plannedStops.isNotEmpty;
      return known && _state.telemetry.currentLap > 0 ? 'NONE' : '--';
    }
    final prediction = _state.fuelPrediction;
    if (!prediction.hasEnoughData || prediction.predictedEmptyLap == null) {
      return '--';
    }
    return 'L${prediction.predictedEmptyLap}';
  }

  NextPitLap? _nextPitLap() => NextPitLap.of(
    _state,
    plannedStops: _plannedStops,
    stopsMade: _raceStateManager.pitStopTracker.stopCount,
  );

  String _pitLapLabel() {
    if (_mode != AppMode.race) return 'PIT LAP';
    final next = _nextPitLap();
    if (next == null) return 'PIT LAP';
    if (next.forFuel) return 'PIT LAP · FUEL';
    final tyre = next.plannedStop!.tireCompound;
    return tyre.isEmpty ? 'PIT LAP · PLAN' : 'PIT LAP · ${_shortTyre(tyre).toUpperCase()}';
  }

  static String _shortTyre(String compound) => switch (compound) {
    'Heavy Wet' => 'Wets',
    'Intermediate' => 'Inters',
    _ => compound.replaceFirst('Racing ', ''),
  };

  /// Red once the stop is close (within 2 laps).
  bool _pitLapAlert() {
    final int? lap;
    if (_mode == AppMode.race) {
      lap = _nextPitLap()?.lap;
    } else {
      final prediction = _state.fuelPrediction;
      lap = prediction.hasEnoughData ? prediction.predictedEmptyLap : null;
    }
    return lap != null && lap - _state.telemetry.currentLap <= 2;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_voiceProblem case final problem?) _voiceProblemBanner(problem),
              Expanded(child: _pageForTab()),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _bottomBar(),
    );
  }

  Widget _pageForTab() => switch (_tab) {
            _Tab.home => _homePage(),
            _Tab.aprl => AprlStandingsView(
              // The league as a whole, so no round or circuit.
              header: TrackHeader(
                roundName: null,
                round: null,
                outline: null,
                accent: Colors.amber.shade800,
                title: 'CHAMPIONSHIP STANDINGS',
                overlineText: LeagueCalendar.season.toUpperCase(),
                details: 'Apex Point Racing League · GT3 Clubman Division',
                emblemIcon: Icons.emoji_events,
                pageTitle: 'APRL',
                pageIcon: Icons.emoji_events,
                statusDots: _connectionDots(),
              ),
            ),
            _ => _modePage(),
          };

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

  /// Telemetry and HUD OCR as dots for the page headings.
  List<Widget> _connectionDots() => [
    StatusBadge(label: 'TELEMETRY', status: _telemetryStatus, dotOnly: true),
    StatusBadge(label: 'HUD OCR', status: _hudStatus, dotOnly: true),
  ];

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
            ..._connectionDots(),
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
        if (_mode == AppMode.race) ...[
          _chip(_raceChipLabel(), color: Colors.red.shade900.withValues(alpha: 0.4), border: Colors.red.shade700),
          _chip('NEW RACE', color: Colors.grey.shade800, border: Colors.grey.shade600, onTap: _confirmNewRace),
        ],
        if (_mode == AppMode.race) ?_timeTrialComparisonChip(),
        if (_mode.rivalCallouts) _rivalChip(),
      ],
    );
  }

  /// e.g. "RACE 3 · LAP 12/32": the race laps are going into, so a wrong
  /// split or merge shows at once (NEW RACE fixes a missed start).
  String _raceChipLabel() {
    final race = _raceStateManager.practiceLapLogger.upcomingRaceNumber;
    final lap = _state.telemetry.currentLap;
    final total = _state.raceLaps?.total;
    if (lap <= 0 || _state.sessionPhase == SessionPhase.offTrack) return 'RACE $race';
    return 'RACE $race · LAP $lap${total == null ? '' : '/$total'}';
  }

  Future<void> _confirmNewRace() async {
    final next = _raceStateManager.practiceLapLogger.laps.fold<int>(0, (m, l) => (l.raceNumber ?? 0) > m ? l.raceNumber! : m) + 1;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start a new race?'),
        content: Text(
          'Your next lap starts Race $next, and fuel, pit stop and call tracking start over. '
          'The app normally sees a new race by itself; use this if it missed one (e.g. a restart on lap 1).',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('NEW RACE')),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(_raceStateManager.startNewRace);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Your next lap starts Race $next'), duration: const Duration(seconds: 2)));
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
            // What the laps are being logged on (the HUD tyre label, the
            // pit stop, or a test's tyre -- see FusedRaceStateManager).
            _raceStateManager.practiceLapLogger.currentTireCompound,
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

  /// " ↑" / " ↓" when the water gauge is clearly rising or falling.
  String _waterArrow() {
    final rate = _state.waterPercentPerMinute;
    if (rate == null || rate.abs() < WaterTrend.steadyPercentPerMinute) return '';
    return rate > 0 ? ' ↑' : ' ↓';
  }

  /// The weather being tested, set by the running stint test (a wet
  /// test's rain preset), and GT7's water gauge -- for information only;
  /// nothing to pick. Hidden when dry with no gauge reading.
  Widget _weatherChip() {
    final weather = _raceStateManager.practiceLapLogger.currentWeather;
    final water = _state.hud.waterPercent;
    if (weather == null && water == null) return const SizedBox.shrink();
    final parts = [?weather, if (water != null) 'WATER ${water.round()}%${_waterArrow()}'];
    return _chip(
      parts.join(' · '),
      color: weather == null ? Colors.grey.shade800 : const Color(0xFF0D47A1),
      border: weather == null ? Colors.grey.shade600 : Colors.lightBlue.shade400,
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
                      child: TelemetryCard(label: _pitLapLabel(), value: _pitLapDisplayValue(), alert: _pitLapAlert()),
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
    final onTrack = _state.sessionPhase == SessionPhase.driving && _telemetryStatus == ConnectionStatus.live;
    final stintLapsDone = stint?.laps.length ?? 0;

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
                    // On track: the lap being driven in this stint (so the
                    // first lap shows 1, not 0 until it's done); otherwise
                    // the laps completed.
                    tile(
                      [
                        onTrack ? 'ON LAP' : 'LAPS',
                        if ((stint?.excludedLaps.length ?? 0) > 0) '${stint!.excludedLaps.length} OFF-PACE',
                      ].join(' · '),
                      '${onTrack ? stintLapsDone + 1 : stintLapsDone}${expected == null ? '' : ' / ~$expected'}',
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
