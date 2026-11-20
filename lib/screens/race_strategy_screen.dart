import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import '../models/race_briefing.dart';
import '../models/weather_forecast.dart';
import '../models/league_calendar.dart';
import '../models/race_strategy.dart';
import '../models/fuel_prediction.dart';
import '../models/track_info.dart';
import '../models/practice_lap_record.dart';
import '../services/race_strategist_service.dart';
import '../services/track_database.dart';
import '../services/saved_briefing_store.dart';
import '../services/practice_fuel_calculator.dart';
import '../services/fuel_map_measurement.dart';
import '../services/race_lap_estimator.dart';
import '../services/time_trial_store.dart';
import '../models/time_trial_lap.dart';
import '../models/test_plan.dart';
import '../services/test_plan_tracker.dart';
import '../services/strategy_changes.dart';
import '../services/wet_pace_table.dart';
import '../services/base_rates.dart';
import '../services/dry_tyre_pace.dart';

/// Pre-race strategy planning screen: enter this week's APRL driver
/// briefing and get an AI-generated pit-stop strategy, informed by
/// REAL measured fuel consumption from logged practice laps (see
/// PracticeFuelCalculator) rather than a generic baseline guess.
///
/// Previously also had a separate "VALIDATE AGAINST PRACTICE SESSION"
/// step that re-compared the generated strategy against live telemetry
/// after the fact -- removed as redundant: regenerating the strategy
/// (tap "GENERATE STRATEGY" again) already pulls in whatever practice
/// laps have been driven since, which is strictly more accurate than a
/// one-off live-telemetry snapshot comparison.
class RaceStrategyScreen extends StatefulWidget {
  /// Supplied by the caller (dashboard) so this screen can fall back to
  /// the SAME live FuelPredictor already running during a practice
  /// session when generating a strategy, rather than needing its own
  /// separate telemetry connection.
  final FuelPrediction Function() getCurrentFuelPrediction;

  /// Same pattern again, for the logged practice laps -- their average
  /// fuel use (see PracticeFuelCalculator) is preferred over the live
  /// rolling average once enough laps exist.
  final List<PracticeLapRecord> Function() getPracticeLaps;

  const RaceStrategyScreen({super.key, required this.getCurrentFuelPrediction, required this.getPracticeLaps});

  /// The last auto-save, so the dashboard can wait for it before
  /// reloading the round when this screen closes.
  /// The brief's text size, relative to the rest of the app.
  static const double textScale = 1.5;

  /// GT7's sponsor prefixes, moved after the circuit's name in the track list.
  static const _sponsorPrefixes = ['Michelin Raceway ', 'WeatherTech Raceway '];

  /// "Michelin Raceway Road Atlanta" -> "Road Atlanta (Michelin Raceway)"; other names as they are.
  static String trackLabel(String name) {
    for (final prefix in _sponsorPrefixes) {
      if (name.startsWith(prefix)) return '${name.substring(prefix.length)} (${prefix.trim()})';
    }
    return name;
  }

  /// The star's footnote: the plan isn't yet built on the driver's own
  /// practice stints.
  static String notValidatedNote(RaceStrategy strategy) =>
      '★ Not validated yet: full practice stints are required. '
      '${strategy.testsPlanned > 0 ? '${strategy.testsDone} of ${strategy.testsPlanned} stint tests done. ' : ''}'
      'Run them in Practice, then generate the strategy again.';

  static Future<void> lastSave = Future.value();

  @override
  State<RaceStrategyScreen> createState() => _RaceStrategyScreenState();
}

/// GT7's own option taxonomy for these settings, used to populate the
/// dropdowns below so entry matches exactly what's shown in-game
/// (avoids free-text typos like "Gr3"/"gr 3" confusing the strategist).
const List<double> _multiplierOptions = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0];
final List<double> _refuelSpeedOptions = List.generate(16, (i) => (i + 1).toDouble());

/// APRL races are always restricted to GT7's "Racing" tyre category
/// (never Comfort/Sports), with Intermediate and Heavy Wet additionally
/// always legal regardless of the dry-tyre selection -- so there's no
/// need for a useable-tyre-category dropdown at all, just one fixed
/// compound chip list covering every option that could ever apply.
const List<String> _tireCompoundOptions = ['Racing Hard', 'Racing Medium', 'Racing Soft', 'Intermediate', 'Heavy Wet'];

/// The slicks the driver picks from; at least one is always ticked.
const List<String> _dryCompoundOptions = ['Racing Hard', 'Racing Medium', 'Racing Soft'];

/// Always available in GT7 races, so not shown to pick -- added to every brief.
const List<String> _wetCompounds = ['Intermediate', 'Heavy Wet'];
const List<int> _mandatoryPitStopOptions = [0, 1, 2, 3];


/// Every lap count from 1-120 -- enough for a 90-minute race on a short
/// lap, as a plain dropdown avoids fat-finger typos (e.g. "32" vs "320")
/// more reliably than free text entry.
final List<int> _totalLapsOptions = List.generate(120, (i) => i + 1);

class _RaceStrategyScreenState extends State<RaceStrategyScreen> {
  late final RaceStrategistService _strategist;
  late final Future<List<TrackInfo>> _tracksFuture;

  /// The round's saved name -- set by picking a round from the league
  /// calendar dropdown (see LeagueCalendar).
  final _roundNameController = TextEditingController(text: LeagueCalendar.rounds.first.name);
  final _raceLengthMinutesController = TextEditingController();
  final _fuelController = TextEditingController(text: '100');
  final _weatherController = TextEditingController();
  bool _savedBriefingLoaded = false;

  String? _trackName;
  int _totalLaps = _totalLapsOptions.first;
  double _tyreWearMultiplier = 1.0;
  double _fuelConsumptionMultiplier = 1.0;
  double _refuelingSpeed = 8.0;
  /// The slicks ticked (wet tyres are always available, see _wetCompounds).
  final Set<String> _selectedTireCompounds = {'Racing Hard', 'Racing Medium'};
  String _mandatoryTyreCompound = 'N/A';
  int _mandatoryPitStopCount = 0;

  RaceStrategy? _strategy;
  bool _loading = false;
  String? _error;

  /// Whether the currently-displayed _strategy was computed using REAL
  /// measured fuel consumption from logged practice laps, rather than
  /// the generic baseline assumption -- shown as a badge on the
  /// strategy card so the driver knows which one they're looking at.
  bool _usedMeasuredFuelData = false;

  /// Whether that measured figure came from the logged practice laps
  /// (PracticeFuelCalculator) rather than FuelPredictor's live rolling
  /// average -- shown on the badge so the driver knows the source.
  bool _usedPracticeLapFuelData = false;

  /// GT7's on-screen "Pit Stop Time" for this track (whole stop,
  /// including service), saved with the briefing.
  final _pitStopTimeController = TextEditingController();

  /// Where you start, from qualifying, and the cars on the grid (blank:
  /// 16) -- the tyre order (see PitStopCalculator.startsNearFront).
  final _gridPositionController = TextEditingController();
  final _gridSizeController = TextEditingController();

  /// The brief saves itself: every edit is written shortly after it's
  /// made (no Save button). Held off until the saved brief has loaded,
  /// and while switching rounds, so defaults never overwrite a saved one.
  bool _autoSaveReady = false;
  Timer? _saveTimer;
  String? _lastSavedJson;

  void _scheduleSave() {
    if (!_autoSaveReady) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _saveNow);
  }

  String get _roundName => _roundNameController.text.trim().isEmpty ? 'Round 1' : _roundNameController.text.trim();

  /// The form as it would be saved, or null if it isn't complete.
  String? _formJson() {
    final briefing = _buildBriefingFromForm(quiet: true);
    return briefing == null ? null : jsonEncode([_roundName, briefing.toMap(), _strategy?.toMap()]);
  }

  /// Saves the form as it stands, if it's complete and has changed.
  void _saveNow() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_autoSaveReady) return;
    final briefing = _buildBriefingFromForm(quiet: true);
    if (briefing == null) return;
    final name = _roundName;
    final json = jsonEncode([name, briefing.toMap(), _strategy?.toMap()]);
    if (json == _lastSavedJson) return;
    _lastSavedJson = json;
    RaceStrategyScreen.lastSave = SavedBriefingStore.save(name: name, briefing: briefing, strategy: _strategy);
  }

  @override
  void initState() {
    super.initState();
    _strategist = RaceStrategistService(dotenv.env['GROQ_API_KEY'] ?? '');
    _tracksFuture = TrackDatabase.load();
    for (final c in [
      _raceLengthMinutesController,
      _fuelController,
      _weatherController,
      _pitStopTimeController,
      _gridPositionController,
      _gridSizeController,
    ]) {
      c.addListener(_scheduleSave);
    }
    // Opening the brief saves nothing: only edits after it has loaded
    // (and the track list has filled the track) count.
    Future.wait([_loadSavedBriefing(), _tracksFuture]).whenComplete(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _lastSavedJson = _formJson();
        _autoSaveReady = true;
      });
    });
    TimeTrialStore.load().then((laps) {
      if (mounted) setState(() => _timeTrialBest = TimeTrialLap.best(laps));
    });
    _raceLengthMinutesController.addListener(() => setState(() {}));
  }

  TimeTrialLap? _timeTrialBest;

  /// Race pace for a timed race's lap count: the typical (median) clean
  /// lap from practice and test races, or else the time-trial best
  /// plus 2% (race fuel and wear); null if neither exists yet.
  (int, String)? _racePace() {
    final clean = [
      for (final lap in widget.getPracticeLaps())
        if (!lap.isPitLap && lap.lapTimeMs > 0) lap.lapTimeMs,
    ]..sort();
    if (clean.length >= 3) return (clean[clean.length ~/ 2], 'your typical stint lap');
    final best = _timeTrialBest;
    if (best != null) return ((best.lapTimeMs * 1.02).round(), 'time-trial best + 2%');
    return null;
  }

  /// Under the laps/time row for a timed race: the lap count at race
  /// pace, with a button to use it.
  Widget _timedRaceLapsHint() {
    final minutes = int.tryParse(_raceLengthMinutesController.text.trim());
    if (minutes == null || minutes <= 0) return const SizedBox.shrink();
    final pace = _racePace();
    final style = TextStyle(color: Colors.grey.shade400, fontSize: 14);
    if (pace == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          'Timed race: set total laps to your estimate. Log some laps (Practice or Time Trialing) '
          'and the app suggests it. During the race the lap count is re-estimated from your pace.',
          style: style,
        ),
      );
    }
    final (lapMs, source) = pace;
    final laps = RaceLapEstimator.lapsFor(minutes, lapMs).clamp(1, _totalLapsOptions.last);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$minutes min ≈ $laps laps at ${TimeTrialLap.format(lapMs)} ($source). '
              'Re-estimated from your pace during the race.',
              style: style,
            ),
          ),
          if (laps != _totalLaps)
            TextButton(onPressed: () => setState(() => _totalLaps = laps), child: Text('USE $laps')),
        ],
      ),
    );
  }

  /// A whole-number field (grid position, cars), or null if empty/invalid.
  static int? _enteredCount(TextEditingController c) {
    final value = int.tryParse(c.text.trim());
    return value != null && value > 0 ? value : null;
  }

  /// The pit stop time field as a number, or null if empty/invalid.
  double? _enteredPitStopTime() {
    final value = double.tryParse(_pitStopTimeController.text.trim());
    return value != null && value > 0 ? value : null;
  }

  @override
  void dispose() {
    if (_saveTimer != null) _saveNow(); // an edit still waiting to be saved
    _roundNameController.dispose();
    _raceLengthMinutesController.dispose();
    _fuelController.dispose();
    _weatherController.dispose();
    _pitStopTimeController.dispose();
    _gridPositionController.dispose();
    _gridSizeController.dispose();
    super.dispose();
  }

  /// Restores the single saved briefing (+ its last-generated strategy
  /// into every form field, so the screen comes back exactly as it was
  /// left last time the driver saved -- this is what makes "load it up
  /// every time the app starts" work without the driver re-entering
  /// the same weekly briefing.
  Future<void> _loadSavedBriefing() async {
    final (name, briefing, strategy, _, _) = await SavedBriefingStore.load();
    if (!mounted) return;
    if (briefing == null) {
      // A round picked on the home page but not yet briefed: start from
      // what the calendar says about it.
      if (name != null) setState(() => _applyCalendarRound(name));
      return;
    }
    setState(() => _applyBriefing(name, briefing, strategy));
  }

  /// Fills the form from a saved briefing.
  void _applyBriefing(String? name, RaceBriefing briefing, RaceStrategy? strategy) {
    if (name != null) _roundNameController.text = name;
    _trackName = briefing.trackName;
    _totalLaps = briefing.totalLaps;
    _raceLengthMinutesController.text = briefing.raceLengthMinutes?.toString() ?? '';
    _tyreWearMultiplier = briefing.tyreWearMultiplier;
    _fuelConsumptionMultiplier = briefing.fuelConsumptionMultiplier;
    _refuelingSpeed = briefing.refuelingSpeedLitersPerSec;
    _pitStopTimeController.text = briefing.pitStopTimeSeconds?.toString() ?? '';
    _gridPositionController.text = briefing.gridPosition?.toString() ?? '';
    _gridSizeController.text = briefing.gridSize?.toString() ?? '';
    _fuelController.text = briefing.startingFuelPercent.toString();
    _selectedTireCompounds
      ..clear()
      ..addAll(briefing.availableTireCompounds.where(_dryCompoundOptions.contains));
    if (_selectedTireCompounds.isEmpty) _selectedTireCompounds.add('Racing Medium');
    _mandatoryTyreCompound = briefing.mandatoryTyreCompound;
    _mandatoryPitStopCount = briefing.mandatoryPitStopCount;
    _weatherController.text = briefing.weatherSlots;
    _strategy = strategy;
    _savedBriefingLoaded = true;
  }

  /// Names the briefing after round [name] and fills in what the league
  /// calendar says about it: the track and a timed race length for
  /// enduros. (The weather comes from the weekly brief.)
  void _applyCalendarRound(String name) {
    _roundNameController.text = name;
    // Last round's grid isn't this one's.
    _gridPositionController.clear();
    _gridSizeController.clear();
    final round = LeagueCalendar.byName(name);
    if (round == null) return;
    _trackName = round.gt7Track;
    if (round.raceLengthMinutes != null) {
      _raceLengthMinutesController.text = round.raceLengthMinutes.toString();
    }
  }

  /// The round picker changed: that round's own saved briefing if it has
  /// one, otherwise the calendar's details for it.
  Future<void> _switchRound(String name) async {
    _saveNow(); // the round being left
    _autoSaveReady = false;
    setState(() => _applyCalendarRound(name));
    final saved = await SavedBriefingStore.briefingFor(name);
    if (mounted && saved != null && _roundNameController.text == name) {
      setState(() => _applyBriefing(name, saved.$1, saved.$2));
    }
    _autoSaveReady = true;
    _scheduleSave(); // makes it the active round, as Save used to
  }

  /// Builds a RaceBriefing from whatever is CURRENTLY in the form
  /// fields, or null (with _error set) if required fields are missing.
  /// Used by both _generateStrategy() and the auto-save, so what's saved
  /// is always the latest on-screen edits.
  RaceBriefing? _buildBriefingFromForm({bool quiet = false}) {
    final fuel = double.tryParse(_fuelController.text.trim());
    final raceLengthMinutes = int.tryParse(_raceLengthMinutesController.text.trim());

    if (_trackName == null || fuel == null || _selectedTireCompounds.isEmpty) {
      if (!quiet) setState(() => _error = 'Pick a track, starting fuel %, and at least one tire compound.');
      return null;
    }
    // Every race has weather: one slot ("C01") or several in race order.
    final weatherText = _weatherController.text.trim();
    final weather = WeatherForecast.tryParse(weatherText);
    if (weatherText.isEmpty && !quiet) {
      setState(() => _error = 'Enter the race weather from the brief, e.g. C01 or R06/R05/C03/S14.');
      return null;
    }
    if (weatherText.isNotEmpty && weather == null) {
      if (!quiet) setState(() => _error = 'Weather slots should look like R06/R05/C03/S14 (R rain, C cloudy, S sunny).');
      return null;
    }

    return RaceBriefing(
      trackName: _trackName!,
      totalLaps: _totalLaps,
      raceLengthMinutes: raceLengthMinutes,
      tyreWearMultiplier: _tyreWearMultiplier,
      fuelConsumptionMultiplier: _fuelConsumptionMultiplier,
      refuelingSpeedLitersPerSec: _refuelingSpeed,
      pitStopTimeSeconds: _enteredPitStopTime(),
      startingFuelPercent: fuel,
      // No finish fuel reserve and no tyre-stint cap: stints are set by
      // fuel range and the weather (both off the form).
      finishFuelReservePercent: 0,
      maxTyreStintLaps: 0,
      availableTireCompounds: [
        for (final c in _dryCompoundOptions)
          if (_selectedTireCompounds.contains(c)) c,
        ..._wetCompounds,
      ],
      mandatoryTyreCompound: _mandatoryTyreCompound,
      mandatoryPitStopCount: _mandatoryPitStopCount,
      // Wet if any slot rains; the brief's slots are the only weather input.
      wetOrChangeableWeather: weather?.slots.any((slot) => slot.isRain) ?? false,
      weatherSlots: weather?.code ?? '',
      gridPosition: _enteredCount(_gridPositionController),
      gridSize: _enteredCount(_gridSizeController),
    );
  }

  Future<void> _generateStrategy() async {
    final briefing = _buildBriefingFromForm();
    if (briefing == null) return;
    // The plan being replaced, to say what changed.
    final previous = _strategy;

    setState(() {
      _loading = true;
      _error = null;
      _strategy = null;
    });

    try {
      // Passing the real track length (when known) makes
      // PitStopCalculator's fuel-per-lap estimate scale correctly for
      // very long/short circuits rather than assuming a fixed
      // reference length -- purely an accuracy improvement, doesn't
      // affect determinism since it's the same lookup every time.
      final tracks = await _tracksFuture;
      final trackLengthMeters = tracks
          .where((t) => t.name == briefing.trackName)
          .map((t) => t.trackLengthMeters)
          .firstOrNull;

      // Use REAL measured fuel consumption from logged practice laps,
      // when enough data exists, instead of the generic baseline
      // assumption -- this is what makes practice laps actually
      // influence the generated strategy itself, not just validate it
      // after the fact. Prefer the average over logged practice laps
      // (pit laps excluded) once there are enough; fall back to the
      // live rolling average otherwise.
      final practiceLaps = widget.getPracticeLaps();
      // This round's laps only: the live fuel figure could be from
      // another track or fuel setting -- earlier rounds come in through
      // the base rates below, scaled to this round.
      final measuredPercentPerLap = PracticeFuelCalculator.averagePercentPerLap(practiceLaps);

      // Fuel use and tyre wear from every round driven so far.
      BaseRates baseRates;
      try {
        baseRates = await BaseRates.load();
      } catch (_) {
        baseRates = BaseRates.none;
      }

      // GT7's own pit stop time for this track, if entered.
      final measuredPitStopTimeLossSeconds = briefing.pitStopTimeSeconds;

      final generated = await _strategist.generateStrategy(
        briefing,
        trackLengthMeters: trackLengthMeters,
        measuredPercentPerLap: measuredPercentPerLap,
        measuredPitStopTimeLossSeconds: measuredPitStopTimeLossSeconds,
        // Your wet testing decides each wet spell's tyre, where it covers it.
        wetPace: WetPaceTable.fromLaps(practiceLaps),
        baseRates: baseRates,
        // Your typical lap here (median, pit laps out): what a fuel map's
        // pace cost is a share of.
        lapTimeSeconds: () {
          final times = [for (final l in practiceLaps) if (!l.isPitLap && l.lapTimeMs > 0 && (l.fuelMap ?? 1) == 1) l.lapTimeMs]..sort();
          return times.isEmpty ? null : times[times.length ~/ 2] / 1000;
        }(),
        // A fuel map stint test's laps: what that map really saves and costs.
        measuredMaps: FuelMapMeasurement.fromLaps(practiceLaps),
        // Each dry tyre's pace here, and how soon it went off: which tyre
        // each stint goes on.
        dryPace: DryTyrePace.fromLaps(practiceLaps),
      );
      // How much of the round's practice stint testing it rests on.
      // (sized on the fuel measured, as the dashboard's -- see TestPlan.forRound)
      final plan = TestPlan.forRound(briefing, generated, practiceLaps);
      final progress = TestPlanTracker.progress(plan, widget.getPracticeLaps());
      final strategy = generated.withPractice(
        done: progress.statuses.where((s) => s == TestStatus.done).length,
        planned: plan.stints.length,
      );
      setState(() {
        _strategy = strategy;
        _usedMeasuredFuelData = measuredPercentPerLap != null;
        _usedPracticeLapFuelData = measuredPercentPerLap != null;
        _loading = false;
      });
      if (previous != null && mounted) await _showChanges(previous, strategy);
    } catch (error) {
      setState(() {
        _error = 'Strategy generation failed: $error';
        _loading = false;
      });
    }
  }

  /// After regenerating: what's different from the plan it replaced, and
  /// what the new one rests on (measured from practice, or assumed).
  Future<void> _showChanges(RaceStrategy previous, RaceStrategy updated) {
    final changes = StrategyChanges.between(previous, updated);
    final body = TextStyle(color: Colors.grey.shade300, fontSize: 16);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6),
      child: Text(text, style: TextStyle(color: Colors.grey.shade400, fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
    );
    Widget bullet(String text, {Color? colour}) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text('•  $text', style: body.copyWith(color: colour)),
    );
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: Text(
          changes.isEmpty ? 'Strategy unchanged' : 'Strategy updated',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900),
        ),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (changes.isEmpty)
                  Text('Same plan as before.', style: body)
                else ...[
                  heading('WHAT CHANGED'),
                  for (final c in changes) bullet(c, colour: Colors.white),
                ],
                if (updated.basis.isNotEmpty) ...[
                  heading('WHY: WHAT IT\'S BASED ON'),
                  for (final b in updated.basis) bullet(b),
                ],
                if (!updated.validatedByPractice) ...[
                  const SizedBox(height: 6),
                  Text(RaceStrategyScreen.notValidatedNote(updated), style: TextStyle(color: Colors.amber.shade300, fontSize: 15)),
                ],
              ],
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Dropdowns, chips and switches all edit through setState: a rebuild
    // means something may have changed (an unchanged form isn't re-saved).
    _scheduleSave();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('RACE BRIEF', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
      ),
      // Bigger text throughout: the brief is read at arm's length on the iPad.
      body: MediaQuery.withClampedTextScaling(
        minScaleFactor: RaceStrategyScreen.textScale,
        maxScaleFactor: RaceStrategyScreen.textScale * 1.5,
        child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sectionLabel('WEEKLY DRIVER BRIEFING'),
              const SizedBox(height: 8),
              _roundPicker(),
              if (_savedBriefingLoaded) ...[
                const SizedBox(height: 4),
                Text(
                  'Saved automatically as you edit.',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
                ),
              ],
              const SizedBox(height: 8),
              FutureBuilder<List<TrackInfo>>(
                future: _tracksFuture,
                builder: (context, snapshot) {
                  final tracks = snapshot.data ?? const [];
                  if (snapshot.connectionState != ConnectionState.done) {
                    return _dropdown<String>(
                      label: 'Track name (loading...)',
                      value: 'Loading...',
                      items: const ['Loading...'],
                      labelOf: (v) => v,
                      onChanged: (_) {},
                    );
                  }
                  if (tracks.isEmpty) {
                    return _dropdown<String>(
                      label: 'Track name (failed to load track list)',
                      value: 'N/A',
                      items: const ['N/A'],
                      labelOf: (v) => v,
                      onChanged: (_) {},
                    );
                  }
                  _trackName ??= tracks.first.name;
                  return _dropdown<String>(
                    label: 'Track name',
                    value: _trackName!,
                    // By the name drivers use: "Road Atlanta", not GT7's sponsored "Michelin Raceway ...".
                    items: tracks.map((t) => t.name).toList()
                      ..sort((a, b) => RaceStrategyScreen.trackLabel(a).toLowerCase().compareTo(RaceStrategyScreen.trackLabel(b).toLowerCase())),
                    labelOf: RaceStrategyScreen.trackLabel,
                    onChanged: (v) => setState(() => _trackName = v),
                  );
                },
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _dropdown<int>(
                      label: 'Total laps',
                      value: _totalLaps,
                      items: _totalLapsOptions,
                      labelOf: (v) => v.toString(),
                      onChanged: (v) => setState(() => _totalLaps = v!),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _textField(
                      _raceLengthMinutesController,
                      'Time limit (min, optional)',
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              _timedRaceLapsHint(),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _dropdown<double>(
                      label: 'Tyre wear rate',
                      value: _tyreWearMultiplier,
                      items: _multiplierOptions,
                      labelOf: (v) => '${v.toInt()}x',
                      onChanged: (v) => setState(() => _tyreWearMultiplier = v!),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _dropdown<double>(
                      label: 'Fuel consumption rate',
                      value: _fuelConsumptionMultiplier,
                      items: _multiplierOptions,
                      labelOf: (v) => '${v.toInt()}x',
                      onChanged: (v) => setState(() => _fuelConsumptionMultiplier = v!),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: _textField(_fuelController, 'Starting fuel %', keyboardType: TextInputType.number)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _dropdown<double>(
                      label: 'Refueling speed (L/sec)',
                      value: _refuelingSpeed,
                      items: _refuelSpeedOptions,
                      labelOf: (v) => v.toInt().toString(),
                      onChanged: (v) => setState(() => _refuelingSpeed = v!),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _sectionLabel('AVAILABLE TYRE COMPOUNDS'),
              const SizedBox(height: 4),
              Text(
                'Tick at least one. Intermediates and Wets are always available.',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: _dryCompoundOptions.map((compound) {
                  final selected = _selectedTireCompounds.contains(compound);
                  // The last ticked slick can't be unticked.
                  final locked = selected && _selectedTireCompounds.length == 1;
                  return FilterChip(
                    label: Text(compound),
                    selected: selected,
                    tooltip: locked ? 'At least one slick is needed' : null,
                    onSelected: (value) => setState(() {
                      if (value) {
                        _selectedTireCompounds.add(compound);
                      } else if (!locked) {
                        _selectedTireCompounds.remove(compound);
                      }
                    }),
                    selectedColor: Colors.purple.shade700,
                    backgroundColor: Colors.grey.shade900,
                    labelStyle: const TextStyle(color: Colors.white),
                    checkmarkColor: Colors.white,
                  );
                }).toList(),
              ),
              const SizedBox(height: 8),
              _dropdown<String>(
                label: 'Mandatory tyre compound',
                value: _mandatoryTyreOptions.contains(_mandatoryTyreCompound) ? _mandatoryTyreCompound : 'N/A',
                items: _mandatoryTyreOptions,
                labelOf: (v) => v,
                onChanged: (v) => setState(() => _mandatoryTyreCompound = v!),
              ),
              const SizedBox(height: 8),
              _dropdown<int>(
                label: 'Mandatory pit stops',
                value: _mandatoryPitStopCount,
                items: _mandatoryPitStopOptions,
                labelOf: (v) => v.toString(),
                onChanged: (v) => setState(() => _mandatoryPitStopCount = v!),
              ),
              const SizedBox(height: 12),
              _sectionLabel('PIT STOP TIME'),
              const SizedBox(height: 4),
              Text(
                'Read GT7\'s "Pit Stop Time" after a stop and enter it here -- the whole stop, '
                'including the tyre change and refuelling.',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
              ),
              const SizedBox(height: 8),
              _textField(
                _pitStopTimeController,
                'Pit stop time (seconds, e.g. 24.5)',
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 12),
              _sectionLabel('GRID'),
              const SizedBox(height: 4),
              Text(
                'After qualifying, enter where you start and Generate again. From the front third of the grid '
                'the plan runs the faster tyre first; lower down, the slower one first, with the faster tyre at the end.',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: _textField(_gridPositionController, 'Grid position (e.g. 9)', keyboardType: TextInputType.number)),
                  const SizedBox(width: 8),
                  Expanded(child: _textField(_gridSizeController, 'Cars on the grid (blank: 16)', keyboardType: TextInputType.number)),
                ],
              ),
              const SizedBox(height: 8),
              ...[
                TextField(
                  controller: _weatherController,
                  onChanged: (_) => setState(() {}),
                  textCapitalization: TextCapitalization.characters,
                  style: const TextStyle(color: Colors.white, letterSpacing: 1),
                  decoration: InputDecoration(
                    labelText: 'Race weather from the brief (e.g. C01, or R06/R05/C03/S14)',
                    labelStyle: TextStyle(color: Colors.grey.shade500),
                    errorText: _weatherController.text.trim().isEmpty || WeatherForecast.tryParse(_weatherController.text) != null
                        ? null
                        : 'R = rain, C = cloudy, S = sunny, each with its number, separated by /',
                    filled: true,
                    fillColor: Colors.grey.shade900,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                  ),
                ),
                if (WeatherForecast.tryParse(_weatherController.text) case final forecast?) ...[
                  const SizedBox(height: 8),
                  _weatherTimeline(forecast),
                ],
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loading ? null : _generateStrategy,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.purple.shade700,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _loading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('GENERATE STRATEGY', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
              if (_strategy != null) ...[
                const SizedBox(height: 24),
                _sectionLabel('RECOMMENDED STRATEGY'),
                const SizedBox(height: 8),
                _strategyCard(_strategy!),
              ],
            ],
          ),
        ),
      ),
      ),
    );
  }

  /// The slots in race order, coloured rain / dry, with the laps each
  /// rain or dry spell roughly covers at the briefing's lap count.
  Widget _weatherTimeline(WeatherForecast forecast) {
    // Darker blue the heavier the rain.
    Color colour(WeatherSlot s) => switch (s.letter) {
      'R' => Color.lerp(const Color(0xFF64B5F6), const Color(0xFF0D2C8C), (s.number - 1).clamp(0, 7) / 7)!,
      'C' => Colors.blueGrey.shade600,
      _ => Colors.amber.shade700,
    };
    Color tyreColour(WeatherTyre t) => switch (t) {
      WeatherTyre.wets => Colors.lightBlue.shade300,
      WeatherTyre.inters => Colors.lightGreen.shade300,
      WeatherTyre.slicks => Colors.amber.shade200,
    };
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: Colors.grey.shade900, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (final slot in forecast.slots)
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 1.5),
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    color: colour(slot),
                    alignment: Alignment.center,
                    child: Column(
                      children: [
                        Text(slot.code, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                        Text(
                          slot.name,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          for (final phase in forecast.phases)
            Text(
              '${phase.tyre.label}: about laps ${forecast.lapsOfPhase(phase, _totalLaps).$1}-${forecast.lapsOfPhase(phase, _totalLaps).$2}',
              style: TextStyle(color: tyreColour(phase.tyre), fontSize: 14),
            ),
          const SizedBox(height: 4),
          Text(
            'Tyres by community testing: R01-R02 slicks, R03-R05 inters, R06-R08 wets. Assumes the slots are spread evenly '
            'over $_totalLaps laps; light rain can miss the circuit, and the track stays wet for a while after rain stops.',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
    text,
    style: TextStyle(color: Colors.grey.shade400, fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 1.2),
  );

  Widget _textField(TextEditingController controller, String label, {TextInputType? keyboardType, int maxLines = 1}) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.grey.shade500),
        filled: true,
        fillColor: Colors.grey.shade900,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
      ),
    );
  }

  /// All tire compound options + "N/A" -- GT7 allows no mandatory
  /// compound at all for a given week, so "N/A" is always offered.
  List<String> get _mandatoryTyreOptions => ['N/A', ..._tireCompoundOptions];

  /// The league calendar's rounds. Picking one names the briefing after
  /// it and fills in what the calendar says: the track, wet/changeable
  /// weather, and a timed race length for enduros. A briefing saved
  /// under some other name still shows, as an extra entry.
  Widget _roundPicker() {
    final current = _roundNameController.text;
    final names = [
      for (final round in LeagueCalendar.rounds) round.name,
      if (LeagueCalendar.byName(current) == null && current.isNotEmpty) current,
    ];
    final selected = LeagueCalendar.byName(current);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _dropdown<String>(
          label: 'Round (${LeagueCalendar.season})',
          value: current.isEmpty ? names.first : current,
          items: names,
          labelOf: (name) => name,
          onChanged: (name) {
            if (name != null) _switchRound(name);
          },
        ),
        if (selected != null) ...[
          const SizedBox(height: 4),
          Text(selected.details, style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
        ],
      ],
    );
  }

  Widget _dropdown<T>({
    required String label,
    required T value,
    required List<T> items,
    required String Function(T) labelOf,
    required ValueChanged<T?> onChanged,
  }) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.grey.shade500),
        filled: true,
        fillColor: Colors.grey.shade900,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          dropdownColor: Colors.grey.shade900,
          style: const TextStyle(color: Colors.white),
          items: items.map((item) => DropdownMenuItem<T>(value: item, child: Text(labelOf(item)))).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _strategyCard(RaceStrategy strategy) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade800),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (strategy.alternatives.isNotEmpty) ...[
            Text('PLAN A', style: TextStyle(color: Colors.green.shade300, fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
            const SizedBox(height: 6),
          ],
          Text(
            'Starting tire: ${strategy.startingTireCompound}${strategy.validatedByPractice ? '' : ' ★'}',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(strategy.summary, style: TextStyle(color: Colors.grey.shade300)),
          if (!strategy.validatedByPractice) ...[
            const SizedBox(height: 10),
            Text(
              RaceStrategyScreen.notValidatedNote(strategy),
              style: TextStyle(color: Colors.amber.shade300, fontSize: 14),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                '${_usedMeasuredFuelData ? 'Measured' : 'Assumed'} fuel use: '
                '${strategy.assumedPercentPerLap.toStringAsFixed(1)}%/lap'
                '${strategy.fuelMap > 1 ? ' on Fuel Map ${strategy.fuelMap}' : ''}',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
              ),
              if (_usedMeasuredFuelData) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: Colors.green.shade900, borderRadius: BorderRadius.circular(4)),
                  child: Text(
                    _usedPracticeLapFuelData ? 'FROM PRACTICE LAPS' : 'FROM LIVE FUEL AVERAGE',
                    style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ],
          ),
          if (strategy.pitStops.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  '${strategy.pitStopTimeIsMeasured ? 'Entered' : 'Assumed'} pit loss: '
                  '${strategy.totalEstimatedTimeLossSeconds.toStringAsFixed(1)}s total '
                  '(${strategy.pitStops.length} stop${strategy.pitStops.length == 1 ? '' : 's'})',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
                ),
                if (strategy.pitStopTimeIsMeasured) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.green.shade900, borderRadius: BorderRadius.circular(4)),
                    child: const Text(
                      'FROM GT7 PIT STOP TIME',
                      style: TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: 12),
          for (final stop in strategy.pitStops)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: Colors.purple.shade900, borderRadius: BorderRadius.circular(6)),
                    child: Text('LAP ${stop.lap}', style: const TextStyle(color: Colors.white, fontSize: 14)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${stop.tireCompound}${stop.fuelMap > 1 ? ' · Fuel Map ${stop.fuelMap}' : ''} -- ${stop.reasoning}',
                      style: TextStyle(color: Colors.grey.shade300, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          for (final (letter, b) in strategy.alternatives) _planBSection(b, letter),
        ],
      ),
    );
  }

  /// Plan B (or C) under Plan A: a plan to switch to mid-race (from the
  /// race dashboard's PLAN chip), and how much slower it is.
  Widget _planBSection(RaceStrategy b, String letter) {
    final colour = letter == 'C' ? Colors.lightBlue.shade200 : Colors.amber.shade300;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(color: Colors.grey.shade800, height: 24),
        Text(
          'PLAN $letter${b.behindPlanALabel == null ? '' : '  ${b.behindPlanALabel}'}',
          style: TextStyle(color: colour, fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 1.5),
        ),
        const SizedBox(height: 6),
        Text(
          'Starting tire: ${b.startingTireCompound}${b.fuelMap > 1 ? ' · Fuel Map ${b.fuelMap}' : ''}',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(b.summary, style: TextStyle(color: Colors.grey.shade300)),
        const SizedBox(height: 10),
        for (final (i, stop) in b.pitStops.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: letter == 'C' ? Colors.blue.shade900 : Colors.amber.shade900, borderRadius: BorderRadius.circular(6)),
                  child: Text('LAP ${stop.lap}', style: const TextStyle(color: Colors.white, fontSize: 14)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${stop.tireCompound}${stop.fuelMap != b.stintMaps[i] ? ' · Fuel Map ${stop.fuelMap}' : ''}',
                    style: TextStyle(color: Colors.grey.shade300, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        Text(
          'In the race, tap the PLAN chip to switch: the rest of the race is planned again from where you are.',
          style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
        ),
      ],
    );
  }
}
