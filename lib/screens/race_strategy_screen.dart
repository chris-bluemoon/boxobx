import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import '../models/race_briefing.dart';
import '../models/race_strategy.dart';
import '../models/fuel_prediction.dart';
import '../models/track_info.dart';
import '../models/practice_lap_record.dart';
import '../services/race_strategist_service.dart';
import '../services/track_database.dart';
import '../services/saved_briefing_store.dart';
import '../services/practice_fuel_calculator.dart';

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

  const RaceStrategyScreen({
    super.key,
    required this.getCurrentFuelPrediction,
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

  @override
  void initState() {
    super.initState();
    _strategist = RaceStrategistService(dotenv.env['GROQ_API_KEY'] ?? '');
    _tracksFuture = TrackDatabase.load();
    _loadSavedBriefing();
  }

  /// The pit stop time field as a number, or null if empty/invalid.
  double? _enteredPitStopTime() {
    final value = double.tryParse(_pitStopTimeController.text.trim());
    return value != null && value > 0 ? value : null;
  }

  @override
  void dispose() {
    _roundNameController.dispose();
    _raceLengthMinutesController.dispose();
    _fuelController.dispose();
    _finishReserveController.dispose();
    _notesController.dispose();
    _pitStopTimeController.dispose();
    super.dispose();
  }

  /// Restores the single saved briefing (+ its last-generated strategy
  /// into every form field, so the screen comes back exactly as it was
  /// left last time the driver saved -- this is what makes "load it up
  /// every time the app starts" work without the driver re-entering
  /// the same weekly briefing.
  Future<void> _loadSavedBriefing() async {
    final (name, briefing, strategy, _, _) = await SavedBriefingStore.load();
    if (briefing == null) return;

    setState(() {
      if (name != null) _roundNameController.text = name;
      _trackName = briefing.trackName;
      _totalLaps = briefing.totalLaps;
      _raceLengthMinutesController.text = briefing.raceLengthMinutes?.toString() ?? '';
      _tyreWearMultiplier = briefing.tyreWearMultiplier;
      _fuelConsumptionMultiplier = briefing.fuelConsumptionMultiplier;
      _refuelingSpeed = briefing.refuelingSpeedLitersPerSec;
      _pitStopTimeController.text = briefing.pitStopTimeSeconds?.toString() ?? '';
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
      _strategy = strategy;
      _savedBriefingLoaded = true;
    });
  }

  /// Builds a RaceBriefing from whatever is CURRENTLY in the form
  /// fields, or null (with _error set) if required fields are missing.
  /// Used by both _generateStrategy() and _saveBriefing() so that
  /// saving always reflects the latest on-screen edits rather than a
  /// stale briefing object left over from the last time "GENERATE
  /// STRATEGY" was pressed -- previously Save silently persisted that
  /// stale object, so edits made after generating (or after loading a
  /// saved briefing) without re-generating were never actually saved.
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
      pitStopTimeSeconds: _enteredPitStopTime(),
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
      final practiceLapAverage = PracticeFuelCalculator.averagePercentPerLap(practiceLaps);
      final practiceFuelPrediction = widget.getCurrentFuelPrediction();
      final measuredPercentPerLap = practiceLapAverage ??
          (practiceFuelPrediction.hasEnoughData ? practiceFuelPrediction.percentPerLap : null);

      // GT7's own pit stop time for this track, if entered.
      final measuredPitStopTimeLossSeconds = briefing.pitStopTimeSeconds;

      final strategy = await _strategist.generateStrategy(
        briefing,
        trackLengthMeters: trackLengthMeters,
        measuredPercentPerLap: measuredPercentPerLap,
        measuredPitStopTimeLossSeconds: measuredPitStopTimeLossSeconds,
      );
      setState(() {
        _strategy = strategy;
        _usedMeasuredFuelData = measuredPercentPerLap != null;
        _usedPracticeLapFuelData = practiceLapAverage != null;
        _loading = false;
      });
    } catch (error) {
      setState(() {
        _error = 'Strategy generation failed: $error';
        _loading = false;
      });
    }
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
              _sectionLabel('PIT STOP TIME'),
              const SizedBox(height: 4),
              Text(
                'Read GT7\'s "Pit Stop Time" after a stop and enter it here -- the whole stop, '
                'including the tyre change and refuelling.',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
              ),
              const SizedBox(height: 8),
              _textField(
                _pitStopTimeController,
                'Pit stop time (seconds, e.g. 24.5)',
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
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
                    _usedPracticeLapFuelData ? 'FROM PRACTICE LAPS' : 'FROM LIVE FUEL AVERAGE',
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
                  '${strategy.pitStopTimeIsMeasured ? 'Entered' : 'Assumed'} pit loss: '
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
                      'FROM GT7 PIT STOP TIME',
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
}
