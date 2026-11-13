import 'package:flutter/material.dart';

import '../models/championship_standing.dart';
import '../services/championship_standings_store.dart';
import '../services/league_roster.dart';

/// Weekly league championship entry screen: manually enter this week's
/// round points + running total for each driver (position is DERIVED
/// by sorting on total, never entered directly -- see
/// ChampionshipStandingsStore.sortedByPosition), and pick exactly 2
/// rivals to monitor.
///
/// This is Phase A of the "nearest rival" feature -- just the data
/// entry + rival selection. Phase B (live on-track tracking of the
/// chosen rivals' position/strategy during a race) consumes the data
/// persisted here but is built separately.
class ChampionshipScreen extends StatefulWidget {
  const ChampionshipScreen({super.key});

  @override
  State<ChampionshipScreen> createState() => _ChampionshipScreenState();
}

class _ChampionshipScreenState extends State<ChampionshipScreen> {
  // Keyed by driver gamertag -- one controller pair per roster entry,
  // built once in initState so text typed into a field survives
  // re-renders without being tied to a List index that could shift.
  final Map<String, TextEditingController> _totalControllers = {};
  final Map<String, TextEditingController> _roundControllers = {};
  final Set<String> _selectedRivals = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    for (final driver in leagueRoster) {
      _totalControllers[driver] = TextEditingController();
      _roundControllers[driver] = TextEditingController();
    }
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final standings = await ChampionshipStandingsStore.load();
    final rivals = await ChampionshipStandingsStore.loadRivals();
    if (!mounted) return;
    setState(() {
      for (final standing in standings) {
        _totalControllers[standing.driverName]?.text = standing.totalPoints.toString();
        _roundControllers[standing.driverName]?.text = standing.roundPoints.toString();
      }
      _selectedRivals
        ..clear()
        ..addAll(rivals);
      _loading = false;
    });
  }

  @override
  void dispose() {
    for (final controller in _totalControllers.values) {
      controller.dispose();
    }
    for (final controller in _roundControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final standings = <ChampionshipStanding>[];
    for (final driver in leagueRoster) {
      final total = int.tryParse(_totalControllers[driver]!.text.trim());
      final round = int.tryParse(_roundControllers[driver]!.text.trim()) ?? 0;
      // A driver with no total entered yet simply isn't included this
      // week -- e.g. a new roster addition who hasn't raced, or a row
      // the user hasn't gotten to transcribing yet. Not an error.
      if (total == null) continue;
      standings.add(ChampionshipStanding(driverName: driver, totalPoints: total, roundPoints: round));
    }

    await ChampionshipStandingsStore.save(standings);
    await ChampionshipStandingsStore.saveRivals(_selectedRivals.toList());

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Championship standings saved')),
    );
  }

  void _toggleRival(String driver) {
    setState(() {
      if (_selectedRivals.contains(driver)) {
        _selectedRivals.remove(driver);
      } else if (_selectedRivals.length < 2) {
        _selectedRivals.add(driver);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Only 2 rivals can be monitored at once -- deselect one first')),
        );
      }
    });
  }

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
        if (int.tryParse(_totalControllers[driver]!.text.trim()) != null)
          ChampionshipStanding(
            driverName: driver,
            totalPoints: int.parse(_totalControllers[driver]!.text.trim()),
            roundPoints: int.tryParse(_roundControllers[driver]!.text.trim()) ?? 0,
          ),
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
                'Enter this week\'s round points + running total for each driver, from the '
                'league\'s Discord standings report. Position is calculated automatically.',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Text(
                'Tap up to 2 drivers below to monitor as rivals -- ${_selectedRivals.length}/2 selected.',
                style: TextStyle(color: Colors.blue.shade300, fontSize: 12, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView.builder(
                  itemCount: leagueRoster.length,
                  itemBuilder: (context, index) => _driverRow(leagueRoster[index], positionByDriver),
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

  Widget _driverRow(String driver, Map<String, int> positionByDriver) {
    final isRival = _selectedRivals.contains(driver);
    final position = positionByDriver[driver];

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isRival ? Colors.blue.shade900.withValues(alpha: 0.3) : Colors.grey.shade900,
        borderRadius: BorderRadius.circular(8),
        border: isRival ? Border.all(color: Colors.blue.shade700) : null,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              position != null ? 'P$position' : '--',
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              driver,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 70,
            child: TextField(
              controller: _roundControllers[driver],
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(isDense: true, hintText: 'Rnd', hintStyle: TextStyle(fontSize: 11)),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 70,
            child: TextField(
              controller: _totalControllers[driver],
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration:
                  const InputDecoration(isDense: true, hintText: 'Total', hintStyle: TextStyle(fontSize: 11)),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(
              isRival ? Icons.star : Icons.star_border,
              color: isRival ? Colors.amberAccent : Colors.grey.shade600,
              size: 20,
            ),
            tooltip: isRival ? 'Stop monitoring this rival' : 'Monitor as rival',
            onPressed: () => _toggleRival(driver),
          ),
        ],
      ),
    );
  }
}
