import 'package:flutter/material.dart';

import '../models/championship_standing.dart';
import '../services/championship_standings_store.dart';
import '../services/league_roster.dart';
import 'championship_screen.dart';

/// The APRL tab: the league standings as a table (position, driver,
/// points, gap to the leader and to us, rounds raced), our row
/// highlighted, with ENTER RESULTS opening the entry form.
class AprlStandingsView extends StatefulWidget {
  const AprlStandingsView({super.key});

  @override
  State<AprlStandingsView> createState() => _AprlStandingsViewState();
}

class _AprlStandingsViewState extends State<AprlStandingsView> {
  List<ChampionshipStanding>? _standings;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final standings = await ChampionshipStandingsStore.load();
    if (!mounted) return;
    setState(
      () => _standings = ChampionshipStandingsStore.sortedByPosition(standings),
    );
  }

  Future<void> _enterResults() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ChampionshipScreen()));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final standings = _standings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.emoji_events, color: Colors.amber, size: 30),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'APRL STANDINGS',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.5,
                ),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _enterResults,
              icon: const Icon(Icons.edit, color: Colors.white),
              label: const Text(
                'ENTER RESULTS',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.white38),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Apex Point Racing League · GT3 Clubman Division',
          style: TextStyle(color: Colors.grey.shade400, fontSize: 15),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: standings == null
              ? const Center(child: CircularProgressIndicator())
              : standings.isEmpty
              ? Center(
                  child: Text(
                    'No standings yet.\nTap ENTER RESULTS to add each round\'s points from the league\'s Discord report.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 17),
                  ),
                )
              : _table(standings),
        ),
      ],
    );
  }

  Widget _table(List<ChampionshipStanding> standings) {
    final leader = standings.first.totalPoints;
    final me = standings.where((s) => s.driverName == playerName).firstOrNull;
    const head = TextStyle(
      color: Colors.grey,
      fontSize: 14,
      fontWeight: FontWeight.bold,
      letterSpacing: 1,
    );
    Widget cell(
      String text, {
      TextStyle? style,
      TextAlign align = TextAlign.right,
      int flex = 2,
    }) => Expanded(
      flex: flex,
      child: Text(
        text,
        textAlign: align,
        style: style ?? const TextStyle(color: Colors.white, fontSize: 18),
      ),
    );
    String gap(int g) => g == 0 ? 'level' : (g > 0 ? '+$g' : '$g');

    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              cell('POS', style: head, align: TextAlign.left, flex: 1),
              cell('DRIVER', style: head, align: TextAlign.left, flex: 5),
              cell('PTS', style: head),
              cell('TO LEADER', style: head, flex: 3),
              if (me != null) cell('YOUR GAP', style: head),
              cell('RACED', style: head),
            ],
          ),
        ),
        for (final (i, s) in standings.indexed)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: s.driverName == playerName
                  ? Colors.blue.shade900.withValues(alpha: 0.6)
                  : Colors.grey.shade900,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: s.driverName == playerName
                    ? Colors.lightBlue.shade300
                    : Colors.white12,
              ),
            ),
            child: Row(
              children: [
                cell(
                  'P${i + 1}',
                  align: TextAlign.left,
                  flex: 1,
                  style: TextStyle(
                    color: i == 0 ? Colors.amber : Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                cell(
                  s.driverName,
                  align: TextAlign.left,
                  flex: 5,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                cell(
                  '${s.totalPoints}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                cell(
                  i == 0 ? '—' : '${s.totalPoints - leader}',
                  flex: 3,
                  style: TextStyle(color: Colors.grey.shade300, fontSize: 18),
                ),
                if (me != null)
                  cell(
                    s == me ? '—' : gap(me.totalPoints - s.totalPoints),
                    style: TextStyle(
                      color: s == me
                          ? Colors.grey.shade300
                          : (me.totalPoints >= s.totalPoints
                                ? Colors.greenAccent
                                : Colors.orangeAccent),
                      fontSize: 18,
                    ),
                  ),
                cell(
                  '${s.roundsRaced}',
                  style: TextStyle(color: Colors.grey.shade300, fontSize: 18),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
