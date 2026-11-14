import 'package:flutter/material.dart';

import '../models/championship_standing.dart';
import '../services/championship_standings_store.dart';
import '../services/league_roster.dart';

/// Weekly league championship entry screen: manually enter this week's
/// round points + running total for each driver (position is DERIVED
/// by sorting on total, never entered directly -- see
/// ChampionshipStandingsStore.sortedByPosition).
///
/// Standings entry ONLY -- there is deliberately no rival selection UI
/// here. The race rival Boxington tracks on track is picked on the Race
/// Mode screen (see RaceRivalTracker).
class ChampionshipScreen extends StatefulWidget {
  const ChampionshipScreen({super.key});

  @override
  State<ChampionshipScreen> createState() => _ChampionshipScreenState();
}

class _ChampionshipScreenState extends State<ChampionshipScreen> {
  static const int _roundCount = 9;

  // Keyed by driver gamertag -- one controller LIST (one per round,
  // always length 9) plus one drop-points controller per roster entry,
  // built once in initState so text typed into a field survives
  // re-renders without being tied to a List index that could shift.
  final Map<String, List<TextEditingController>> _roundControllers = {};
  final Map<String, TextEditingController> _dropPointsControllers = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    for (final driver in leagueRoster) {
      _roundControllers[driver] = List.generate(_roundCount, (_) => TextEditingController());
      _dropPointsControllers[driver] = TextEditingController();
    }
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final standings = await ChampionshipStandingsStore.load();
    if (!mounted) return;
    setState(() {
      for (final standing in standings) {
        final controllers = _roundControllers[standing.driverName];
        if (controllers == null) continue;
        for (var i = 0; i < _roundCount; i++) {
          controllers[i].text = standing.roundPoints[i]?.toString() ?? '';
        }
        _dropPointsControllers[standing.driverName]?.text = standing.dropPoints.toString();
      }
      _loading = false;
    });
  }

  @override
  void dispose() {
    for (final controllers in _roundControllers.values) {
      for (final controller in controllers) {
        controller.dispose();
      }
    }
    for (final controller in _dropPointsControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Builds a ChampionshipStanding from whatever is currently typed for
  /// one driver, or null if NO round has any score entered yet for
  /// them (a driver who simply hasn't raced/been transcribed this
  /// week -- not an error, just excluded from this save).
  ChampionshipStanding? _buildStandingFromForm(String driver) {
    final roundPoints = [
      for (final controller in _roundControllers[driver]!) int.tryParse(controller.text.trim()),
    ];
    if (roundPoints.every((points) => points == null)) return null;

    final dropPoints = int.tryParse(_dropPointsControllers[driver]!.text.trim()) ?? 0;
    return ChampionshipStanding(driverName: driver, roundPoints: roundPoints, dropPoints: dropPoints);
  }

  Future<void> _save() async {
    final standings = [
      for (final driver in leagueRoster) _buildStandingFromForm(driver),
    ].whereType<ChampionshipStanding>().toList();

    await ChampionshipStandingsStore.save(standings);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Championship standings saved')),
    );
  }

  // Fixed column widths shared between the header row and every driver
  // row, so everything lines up -- both rows are built against this
  // same set of constants rather than each hardcoding widths
  // independently.
  static const double _positionColumnWidth = 32;
  static const double _nameColumnWidth = 160;
  static const double _roundColumnWidth = 48;
  static const double _dropColumnWidth = 56;
  static const double _totalColumnWidth = 56;

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // Live-sorted preview of position as the driver types, so they can
    // see the derived standings take shape without needing to save and
    // reload first.
    final previewStandings = ChampionshipStandingsStore.sortedByPosition([
      for (final driver in leagueRoster)
        if (_buildStandingFromForm(driver) != null) _buildStandingFromForm(driver)!,
    ]);
    final positionByDriver = {
      for (var i = 0; i < previewStandings.length; i++) previewStandings[i].driverName: i + 1,
    };

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('CHAMPIONSHIP'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Enter each round\'s points for every driver, from the league\'s Discord '
                'standings report. Drop points and total are calculated automatically.',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
              ),
              const SizedBox(height: 16),
              // The 9 round columns + drop + total + name + position
              // don't comfortably fit an iPad's width all at once, so
              // the whole table (header included, so column labels
              // scroll in lockstep with the data under them) scrolls
              // horizontally as one unit.
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: _positionColumnWidth +
                        _nameColumnWidth +
                        (_roundColumnWidth * _roundCount) +
                        _dropColumnWidth +
                        _totalColumnWidth +
                        40,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _headerRow(),
                        const SizedBox(height: 8),
                        Expanded(
                          child: ListView.builder(
                            itemCount: leagueRoster.length,
                            itemBuilder: (context, index) => _driverRow(leagueRoster[index], positionByDriver),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue.shade700,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: const Text('SAVE STANDINGS', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerLabel(String text, double width) {
    return SizedBox(
      width: width,
      child: Text(
        text,
        style: TextStyle(color: Colors.grey.shade500, fontSize: 11, fontWeight: FontWeight.bold),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _headerRow() {
    return Row(
      children: [
        _headerLabel('POS', _positionColumnWidth),
        SizedBox(
          width: _nameColumnWidth,
          child: Text(
            'DRIVER',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 11, fontWeight: FontWeight.bold),
          ),
        ),
        for (var i = 1; i <= _roundCount; i++) _headerLabel('R$i', _roundColumnWidth),
        _headerLabel('DROP', _dropColumnWidth),
        _headerLabel('TOTAL', _totalColumnWidth),
      ],
    );
  }

  Widget _roundField(String driver, int roundIndex) {
    return SizedBox(
      width: _roundColumnWidth,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: TextField(
          controller: _roundControllers[driver]![roundIndex],
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 12),
          decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 8)),
          onChanged: (_) => setState(() {}),
        ),
      ),
    );
  }

  Widget _driverRow(String driver, Map<String, int> positionByDriver) {
    final position = positionByDriver[driver];
    final standing = _buildStandingFromForm(driver);

    // Plain, non-interactive row -- display + entry fields only. No
    // tap target, no highlight state: rival selection isn't a concept
    // this screen has at all (the race rival is picked on the Race
    // Mode screen).
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          SizedBox(
            width: _positionColumnWidth,
            child: Text(
              position != null ? 'P$position' : '--',
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
          ),
          SizedBox(
            width: _nameColumnWidth,
            child: Text(
              driver,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          for (var i = 0; i < _roundCount; i++) _roundField(driver, i),
          SizedBox(
            width: _dropColumnWidth,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: TextField(
                controller: _dropPointsControllers[driver],
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
                decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 8)),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ),
          SizedBox(
            width: _totalColumnWidth,
            child: Text(
              standing?.totalPoints.toString() ?? '--',
              style: const TextStyle(color: Colors.greenAccent, fontSize: 13, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
