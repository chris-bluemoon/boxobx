import 'package:flutter/material.dart';

import '../models/championship_standing.dart';
import '../models/league_calendar.dart';
import '../services/aprl_leaderboard_service.dart';
import '../services/championship_outlook.dart';
import '../services/championship_standings_store.dart';
import '../services/league_roster.dart';

/// The APRL tab: the league standings as a table (position, driver,
/// points, gap to the leader and to us, rounds raced), our row
/// highlighted. Filled from the APRL leaderboard each time the tab
/// opens (and on REFRESH).
class AprlStandingsView extends StatefulWidget {
  /// The page heading, the same one the other tabs use.
  final Widget? header;

  const AprlStandingsView({super.key, this.header});

  @override
  State<AprlStandingsView> createState() => _AprlStandingsViewState();
}

class _AprlStandingsViewState extends State<AprlStandingsView> {
  List<ChampionshipStanding>? _standings;

  /// When the standings last came from the leaderboard.
  DateTime? _fetchedAt;
  bool _refreshing = false;

  /// Why the last refresh failed (the saved standings are shown).
  String? _refreshError;

  @override
  void initState() {
    super.initState();
    _load().then((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (_refreshing || !AprlLeaderboardService.enabled) return;
    setState(() {
      _refreshing = true;
      _refreshError = null;
    });
    try {
      await AprlLeaderboardService.refresh();
      await _load();
    } catch (e) {
      if (mounted) setState(() => _refreshError = 'Couldn\'t reach the APRL leaderboard, so these are the saved standings.');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _load() async {
    final standings = await ChampionshipStandingsStore.load();
    final fetchedAt = await AprlLeaderboardService.lastFetched();
    if (!mounted) return;
    setState(() {
      _standings = ChampionshipStandingsStore.sortedByPosition(standings);
      _fetchedAt = fetchedAt;
    });
  }

  @override
  Widget build(BuildContext context) {
    final standings = _standings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.header != null) ...[
          widget.header!,
          const SizedBox(height: 10),
        ],
        Row(
          children: [
            Expanded(child: _sourceLine()),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: _refreshing ? null : _refresh,
              icon: _refreshing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, color: Colors.white),
              label: const Text(
                'REFRESH',
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
        const SizedBox(height: 12),
        Expanded(
          child: standings == null
              ? const Center(child: CircularProgressIndicator())
              : standings.isEmpty
              ? Center(
                  child: Text(
                    _refreshing
                        ? 'Getting the standings from the APRL leaderboard...'
                        : 'No standings yet.\nTap REFRESH to get them from the APRL leaderboard.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 17),
                  ),
                )
              : _table(standings),
        ),
      ],
    );
  }

  /// Where the standings came from, and when.
  Widget _sourceLine() {
    String two(int n) => n.toString().padLeft(2, '0');
    final at = _fetchedAt;
    final text =
        _refreshError ??
        (at == null
            ? 'Entered by hand.'
            : 'From the APRL leaderboard · updated ${at.day}/${at.month} ${two(at.hour)}:${two(at.minute)}');
    return Text(
      text,
      style: TextStyle(
        color: _refreshError != null
            ? Colors.orangeAccent
            : Colors.grey.shade400,
        fontSize: 15,
      ),
    );
  }

  /// What the next round needs against the drivers around us (see
  /// ChampionshipOutlook).
  Widget _outlookCard(ChampionshipOutlook outlook) {
    final line = TextStyle(color: Colors.white, fontSize: 16, height: 1.35);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.lightBlue.shade300.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'WHAT YOU NEED · ROUND ${outlook.nextRound} OF ${outlook.totalRounds}',
            style: TextStyle(color: Colors.lightBlue.shade200, fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1),
          ),
          const SizedBox(height: 8),
          Text(outlook.titleLine(), style: line.copyWith(fontWeight: FontWeight.bold)),
          for (final rival in outlook.rivals)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    rival.ahead ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 18,
                    color: rival.ahead ? Colors.greenAccent : Colors.orangeAccent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(rival.describe(), style: line)),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Text(
            'Around your usual finish (P${outlook.typicalPlace}). Counts each driver\'s lowest round dropped; '
            'leaves out the fastest-lap point. Level on points goes to countback.',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
          ),
        ],
      ),
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

    final outlook = ChampionshipOutlook.of(standings, player: playerName, totalRounds: LeagueCalendar.rounds.length);
    return ListView(
      children: [
        if (outlook != null) _outlookCard(outlook),
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
