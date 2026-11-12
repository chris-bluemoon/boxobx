import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import '../models/race_briefing.dart';
import '../models/race_strategy.dart';
import '../models/strategy_validation.dart';
import '../models/fuel_prediction.dart';
import '../models/tire_wear_estimate.dart';
import '../models/track_info.dart';
import '../models/pit_stop_time_record.dart';
import '../models/practice_lap_record.dart';
import '../services/race_strategist_service.dart';
import '../services/strategy_validator.dart';
import '../services/track_database.dart';
import '../services/saved_briefing_store.dart';
import '../services/pit_stop_time_store.dart';
import '../services/shift_aware_fuel_calculator.dart';

/// Pre-race strategy planning screen: enter this week's APRL driver
/// briefing, get an AI-generated pit-stop strategy, then optionally
/// validate that strategy's fuel assumption AND real tire degradation
/// against a live practice session's telemetry (see StrategyValidator).
class RaceStrategyScreen extends StatefulWidget {
  /// Supplied by the caller (dashboard) so this screen can validate
  /// against the SAME live FuelPredictor already running during a
  /// practice session, rather than needing its own separate telemetry
  /// connection.
  final FuelPrediction Function() getCurrentFuelPrediction;

  /// Same pattern as getCurrentFuelPrediction, for the live
  /// TireWearTracker's lap-time-degradation estimate.
  final TireWearEstimate Function() getCurrentTireWearEstimate;

  /// Same pattern again, for the logged practice laps (lap time, tire,
  /// fuel, AND shift-quality counts) -- used to compute a
  /// shift-quality-weighted fuel average (see
  /// ShiftAwareFuelCalculator) that's preferred over the raw rolling
  /// average when enough clean-lap data exists.
  final List<PracticeLapRecord> Function() getPracticeLaps;

  const RaceStrategyScreen({
    super.key,
    required this.getCurrentFuelPrediction,
    required this.getCurrentTireWearEstimate,
    required this.getPracticeLaps,
  });

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
const List<int> _mandatoryPitStopOptions = [0, 1, 2, 3];

/// 0 disables the tyre-stint cap entirely (stint length is fuel-range
/// only, the original behavior) -- otherwise a realistic range of
/// maximum laps a single tyre set should run, mirroring a standard
/// sim-racing pit-calculator's "maximum tyre stint" input.
const List<int> _maxTyreStintLapsOptions = [0, 5, 8, 10, 12, 15, 18, 20, 25, 30];

/// Every lap count from 1-36 -- covers the full range APRL races use,
/// as a plain dropdown avoids fat-finger typos (e.g. "32" vs "320")
/// more reliably than free text entry.
final List<int> _totalLapsOptions = List.generate(36, (i) => i + 1);

class _RaceStrategyScreenState extends State<RaceStrategyScreen> {
  late final RaceStrategistService _strategist;
  final _strategyValidator = StrategyValidator();
  late final Future<List<TrackInfo>> _tracksFuture;

  final _roundNameController = TextEditingController(text: 'Round 1');
  final _raceLengthMinutesController = TextEditingController();
  final _fuelController = TextEditingController(text: '100');
  final _notesController = TextEditingController();
  bool _savedBriefingLoaded = false;

  String? _trackName;
  int _totalLaps = _totalLapsOptions.first;
  double _tyreWearMultiplier = 1.0;
  double _fuelConsumptionMultiplier = 1.0;
  double _refuelingSpeed = 8.0;
  final _finishReserveController = TextEditingController(text: '0');
  int _maxTyreStintLaps = 0;
  final Set<String> _selectedTireCompounds = {'Racing Hard', 'Racing Medium'};
  String _mandatoryTyreCompound = 'N/A';
  int _mandatoryPitStopCount = 0;
  bool _wetOrChangeableWeather = false;

  RaceBriefing? _briefing;
  RaceStrategy? _strategy;
  StrategyValidation? _validation;
  DateTime? _validatedAt;
  bool _loading = false;
  String? _error;

  /// Whether the currently-displayed _strategy was computed using REAL
  /// measured fuel consumption from logged practice laps, rather than
  /// the generic baseline assumption -- shown as a badge on the
  /// strategy card so the driver knows which one they're looking at.
  bool _usedMeasuredFuelData = false;

  /// Whether that measured figure specifically came from
  /// ShiftAwareFuelCalculator (clean-shift-filtered average across
  /// logged practice laps) rather than FuelPredictor's raw rolling
  /// average -- shown as a more specific badge label, since the
  /// shift-aware figure is a stronger guarantee of what a clean stint
  /// should actually burn.
  bool _usedShiftAwareFuelData = false;

  /// Manually-logged pit-stop time-loss measurements (see
  /// PitStopTimeRecord) -- GT7 has no pit-lane entry/exit telemetry
  /// signal at all, so these are entered by hand after comparing an
  /// in/out lap sequence against a normal lap.
  List<PitStopTimeRecord> _pitStopTimeRecords = [];
  final _pitStopTimeLossController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _strategist = RaceStrategistService(dotenv.env['GROQ_API_KEY'] ?? '');
    _tracksFuture = TrackDatabase.load();
    _loadSavedBriefing();
    _loadPitStopTimeRecords();
  }

  Future<void> _loadPitStopTimeRecords() async {
    final records = await PitStopTimeStore.load();
    if (!mounted) return;
    setState(() => _pitStopTimeRecords = records);
  }

  Future<void> _logPitStopTime() async {
    final seconds = double.tryParse(_pitStopTimeLossController.text.trim());
    if (seconds == null || seconds <= 0) {
      setState(() => _error = 'Enter a valid pit-stop time loss in seconds (e.g. 23.5).');
      return;
    }
    final record = PitStopTimeRecord(
      totalTimeLossSeconds: seconds,
      tireCompoundFitted: _mandatoryTyreCompound != 'N/A' ? _mandatoryTyreCompound : _selectedTireCompounds.firstOrNull ?? 'Racing Medium',
      refuelRateLitersPerSecond: _refuelingSpeed,
      recordedAt: DateTime.now(),
    );
    await PitStopTimeStore.addRecord(record);
    _pitStopTimeLossController.clear();
    await _loadPitStopTimeRecords();
  }

  @override
  void dispose() {
    _roundNameController.dispose();
    _raceLengthMinutesController.dispose();
    _fuelController.dispose();
    _finishReserveController.dispose();
    _notesController.dispose();
    _pitStopTimeLossController.dispose();
    super.dispose();
  }

  /// Restores the single saved briefing (+ its last-generated strategy
  /// and last practice-session validation snapshot, if any) into every
  /// form field, so the screen comes back exactly as it was left last
  /// time the driver saved/validated -- this is what makes "load it up
  /// every time the app starts" work without the driver re-entering
  /// the same weekly briefing OR re-driving practice laps just to see
  /// their last validation result again.
  Future<void> _loadSavedBriefing() async {
    final (name, briefing, strategy, validation, validatedAt) = await SavedBriefingStore.load();
    if (briefing == null) return;

    setState(() {
      if (name != null) _roundNameController.text = name;
      _trackName = briefing.trackName;
      _totalLaps = briefing.totalLaps;
      _raceLengthMinutesController.text = briefing.raceLengthMinutes?.toString() ?? '';
      _tyreWearMultiplier = briefing.tyreWearMultiplier;
      _fuelConsumptionMultiplier = briefing.fuelConsumptionMultiplier;
      _refuelingSpeed = briefing.refuelingSpeedLitersPerSec;
      _fuelController.text = briefing.startingFuelPercent.toString();
      _finishReserveController.text = briefing.finishFuelReservePercent.toString();
      _maxTyreStintLaps = briefing.maxTyreStintLaps;
      _selectedTireCompounds
        ..clear()
        ..addAll(briefing.availableTireCompounds);
      _mandatoryTyreCompound = briefing.mandatoryTyreCompound;
      _mandatoryPitStopCount = briefing.mandatoryPitStopCount;
      _wetOrChangeableWeather = briefing.wetOrChangeableWeather;
      _notesController.text = briefing.additionalNotes;
      _briefing = briefing;
      _strategy = strategy;
      _validation = validation;
      _validatedAt = validatedAt;
      _savedBriefingLoaded = true;
    });
  }

  /// Builds a RaceBriefing from whatever is CURRENTLY in the form
  /// fields, or null (with _error set) if required fields are missing.
  /// Used by both _generateStrategy() and _saveBriefing() so that
  /// saving always reflects the latest on-screen edits rather than a
  /// stale _briefing left over from the last time "GENERATE STRATEGY"
  /// was pressed -- previously Save silently persisted that stale
  /// object, so edits made after generating (or after loading a saved
  /// briefing) without re-generating were never actually saved.
  RaceBriefing? _buildBriefingFromForm() {
    final fuel = double.tryParse(_fuelController.text.trim());
    final raceLengthMinutes = int.tryParse(_raceLengthMinutesController.text.trim());
    final finishReserve = double.tryParse(_finishReserveController.text.trim()) ?? 0.0;

    if (_trackName == null || fuel == null || _selectedTireCompounds.isEmpty) {
      setState(() => _error = 'Pick a track, starting fuel %, and at least one tire compound.');
      return null;
    }

    return RaceBriefing(
      trackName: _trackName!,
      totalLaps: _totalLaps,
      raceLengthMinutes: raceLengthMinutes,
      tyreWearMultiplier: _tyreWearMultiplier,
      fuelConsumptionMultiplier: _fuelConsumptionMultiplier,
      refuelingSpeedLitersPerSec: _refuelingSpeed,
      startingFuelPercent: fuel,
      finishFuelReservePercent: finishReserve,
      maxTyreStintLaps: _maxTyreStintLaps,
      availableTireCompounds: _selectedTireCompounds.toList(),
      mandatoryTyreCompound: _mandatoryTyreCompound,
      mandatoryPitStopCount: _mandatoryPitStopCount,
      wetOrChangeableWeather: _wetOrChangeableWeather,
      additionalNotes: _notesController.text.trim(),
    );
  }

  Future<void> _saveBriefing() async {
    final briefing = _buildBriefingFromForm();
    if (briefing == null) return;
    await SavedBriefingStore.save(
      name: _roundNameController.text.trim().isEmpty ? 'Round 1' : _roundNameController.text.trim(),
      briefing: briefing,
      strategy: _strategy,
    );
    if (!mounted) return;
    setState(() => _briefing = briefing);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved as "${_roundNameController.text.trim()}"')),
    );
  }

  Future<void> _generateStrategy() async {
    final briefing = _buildBriefingFromForm();
    if (briefing == null) return;

    setState(() {
      _loading = true;
      _error = null;
      _strategy = null;
      _validation = null;
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
      // after the fact. Prefer the shift-quality-weighted average
      // (excludes laps with a lot of short-shifting/over-revving,
      // which burn more fuel than a clean lap for the same distance)
      // when enough clean-lap data exists; fall back to the raw live
      // rolling average otherwise.
      final practiceLaps = widget.getPracticeLaps();
      final cleanShiftAverage = ShiftAwareFuelCalculator.averagePercentPerLap(practiceLaps);
      final practiceFuelPrediction = widget.getCurrentFuelPrediction();
      final measuredPercentPerLap = cleanShiftAverage ??
          (practiceFuelPrediction.hasEnoughData ? practiceFuelPrediction.percentPerLap : null);

      // Real measured pit-stop time loss (in-lap + stationary + out-lap
      // vs. a normal lap), averaged across however many stops the
      // driver has manually logged -- see PitStopTimeStore.
      final measuredPitStopTimeLossSeconds = PitStopTimeStore.averageTimeLossSeconds(_pitStopTimeRecords);

      final strategy = await _strategist.generateStrategy(
        briefing,
        trackLengthMeters: trackLengthMeters,
        measuredPercentPerLap: measuredPercentPerLap,
        measuredPitStopTimeLossSeconds: measuredPitStopTimeLossSeconds,
      );
      setState(() {
        _briefing = briefing;
        _strategy = strategy;
        _usedMeasuredFuelData = measuredPercentPerLap != null;
        _usedShiftAwareFuelData = cleanShiftAverage != null;
        _loading = false;
      });
    } catch (error) {
      setState(() {
        _error = 'Strategy generation failed: $error';
        _loading = false;
      });
    }
  }

  /// Validates against whatever telemetry is live RIGHT NOW, then
  /// persists the result into the SAME saved-briefing slot (see
  /// SavedBriefingStore.saveValidation) -- this is how practice-lap
  /// data gets associated with "Round 5" (or whichever round is
  /// currently saved): since there's only ever one saved round at a
  /// time, every validation implicitly belongs to it, and survives an
  /// app restart without needing to re-drive practice laps.
  Future<void> _validateAgainstPractice() async {
    if (_strategy == null || _briefing == null) return;
    final prediction = widget.getCurrentFuelPrediction();
    final tireWearEstimate = widget.getCurrentTireWearEstimate();
    final validation = _strategyValidator.evaluate(
      strategy: _strategy!,
      briefing: _briefing!,
      practiceFuelPrediction: prediction,
      tireWearEstimate: tireWearEstimate,
    );

    await SavedBriefingStore.saveValidation(validation);

    if (!mounted) return;
    setState(() {
      _validation = validation;
      _validatedAt = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('RACE STRATEGY'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sectionLabel('WEEKLY DRIVER BRIEFING'),
              const SizedBox(height: 8),
              _textField(_roundNameController, 'Round name (e.g. "Round 5")'),
              if (_savedBriefingLoaded) ...[
                const SizedBox(height: 4),
                Text(
                  'Loaded saved briefing from last session.',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
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
                    items: tracks.map((t) => t.name).toList(),
                    labelOf: (v) => v,
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
              Row(
                children: [
                  Expanded(
                    child: _textField(
                      _finishReserveController,
                      'Finish fuel reserve % (safety margin)',
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _dropdown<int>(
                      label: 'Max tyre stint (laps, 0 = no cap)',
                      value: _maxTyreStintLaps,
                      items: _maxTyreStintLapsOptions,
                      labelOf: (v) => v == 0 ? 'No cap' : v.toString(),
                      onChanged: (v) => setState(() => _maxTyreStintLaps = v!),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _sectionLabel('AVAILABLE TYRE COMPOUNDS'),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: _tireCompoundOptions.map((compound) {
                  final selected = _selectedTireCompounds.contains(compound);
                  return FilterChip(
                    label: Text(compound),
                    selected: selected,
                    onSelected: (value) => setState(() {
                      if (value) {
                        _selectedTireCompounds.add(compound);
                      } else {
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
              _sectionLabel('PIT STOP TIME LOSS (measured)'),
              const SizedBox(height: 4),
              Text(
                'Drive an in-lap + stationary + out-lap sequence, compare the total '
                'vs. a normal lap, then log the difference in seconds below.',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _textField(
                      _pitStopTimeLossController,
                      'Time lost this stop (seconds, e.g. 23.5)',
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _logPitStopTime,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade800,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                    ),
                    child: const Text('LOG'),
                  ),
                ],
              ),
              if (_pitStopTimeRecords.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '${_pitStopTimeRecords.length} stop${_pitStopTimeRecords.length == 1 ? '' : 's'} logged -- '
                  'average ${PitStopTimeStore.averageTimeLossSeconds(_pitStopTimeRecords)!.toStringAsFixed(1)}s loss',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                ),
              ],
              const SizedBox(height: 8),
              SwitchListTile(
                value: _wetOrChangeableWeather,
                onChanged: (value) => setState(() => _wetOrChangeableWeather = value),
                title: const Text('Wet / changeable weather', style: TextStyle(color: Colors.white)),
                activeColor: Colors.greenAccent,
                tileColor: Colors.grey.shade900,
              ),
              const SizedBox(height: 8),
              _textField(_notesController, 'Additional notes (grid penalties, etc.)', maxLines: 3),
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
                    : const Text(
                        'GENERATE STRATEGY',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: _saveBriefing,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: Colors.grey.shade600),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: const Text(
                  'SAVE BRIEFING FOR NEXT TIME',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ),
              if (_strategy != null) ...[
                const SizedBox(height: 24),
                _sectionLabel('RECOMMENDED STRATEGY'),
                const SizedBox(height: 8),
                _strategyCard(_strategy!),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _validateAgainstPractice,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade700,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text(
                    'VALIDATE AGAINST PRACTICE SESSION',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ),
                if (_validation != null) ...[
                  const SizedBox(height: 16),
                  _validationCard(_validation!),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
        text,
        style: TextStyle(
          color: Colors.grey.shade400,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      );

  Widget _textField(
    TextEditingController controller,
    String label, {
    TextInputType? keyboardType,
    int maxLines = 1,
  }) {
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
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  /// All tire compound options + "N/A" -- GT7 allows no mandatory
  /// compound at all for a given week, so "N/A" is always offered.
  List<String> get _mandatoryTyreOptions => ['N/A', ..._tireCompoundOptions];

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
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          dropdownColor: Colors.grey.shade900,
          style: const TextStyle(color: Colors.white),
          items: items
              .map((item) => DropdownMenuItem<T>(value: item, child: Text(labelOf(item))))
              .toList(),
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
          Text(
            'Starting tire: ${strategy.startingTireCompound}',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(strategy.summary, style: TextStyle(color: Colors.grey.shade300)),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                '${_usedMeasuredFuelData ? 'Measured' : 'Assumed'} fuel use: '
                '${strategy.assumedPercentPerLap.toStringAsFixed(2)}%/lap',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
              ),
              if (_usedMeasuredFuelData) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.green.shade900,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _usedShiftAwareFuelData ? 'FROM CLEAN PRACTICE LAPS' : 'FROM PRACTICE LAPS',
                    style: const TextStyle(color: Colors.greenAccent, fontSize: 9, fontWeight: FontWeight.bold),
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
                  '${strategy.pitStopTimeIsMeasured ? 'Measured' : 'Assumed'} pit loss: '
                  '${strategy.totalEstimatedTimeLossSeconds.toStringAsFixed(1)}s total '
                  '(${strategy.pitStops.length} stop${strategy.pitStops.length == 1 ? '' : 's'})',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
                if (strategy.pitStopTimeIsMeasured) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.green.shade900,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'FROM LOGGED STOPS',
                      style: TextStyle(color: Colors.greenAccent, fontSize: 9, fontWeight: FontWeight.bold),
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
                    decoration: BoxDecoration(
                      color: Colors.purple.shade900,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text('LAP ${stop.lap}', style: const TextStyle(color: Colors.white, fontSize: 12)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${stop.tireCompound} -- ${stop.reasoning}',
                      style: TextStyle(color: Colors.grey.shade300, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _formatValidatedAt(DateTime time) {
    final now = DateTime.now();
    final sameDay = time.year == now.year && time.month == now.month && time.day == now.day;
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return sameDay ? 'today at $h:$m' : '${time.month}/${time.day} at $h:$m';
  }

  Widget _validationCard(StrategyValidation validation) {
    final (label, color) = switch (validation.fitness) {
      StrategyFitness.insufficientData => ('Not enough practice laps yet', Colors.grey),
      StrategyFitness.onPlan => ('On plan -- real consumption matches the strategy', Colors.greenAccent),
      StrategyFitness.burningMoreThanPlanned => (
          'Burning MORE fuel than planned -- pit earlier',
          Colors.redAccent
        ),
      StrategyFitness.burningLessThanPlanned => (
          'Burning LESS fuel than planned -- can extend the stint',
          Colors.lightBlueAccent
        ),
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
          if (_validatedAt != null) ...[
            const SizedBox(height: 4),
            Text(
              'Validated for "${_roundNameController.text.trim()}" ${_formatValidatedAt(_validatedAt!)}',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 11, fontStyle: FontStyle.italic),
            ),
          ],
          if (validation.actualPercentPerLap != null) ...[
            const SizedBox(height: 8),
            Text(
              'Planned: ${validation.assumedPercentPerLap.toStringAsFixed(2)}%/lap   '
              'Actual: ${validation.actualPercentPerLap!.toStringAsFixed(2)}%/lap',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
            ),
          ],
          if (validation.recommendedPitLap != null) ...[
            const SizedBox(height: 8),
            Text(
              'Recommended pit lap at real consumption: L${validation.recommendedPitLap}',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ],
          if (validation.tireWearWarning != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.shade900.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                validation.tireWearWarning!,
                style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
