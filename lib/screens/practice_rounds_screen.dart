import 'package:flutter/material.dart';

import '../models/league_calendar.dart';
import '../models/practice_lap_record.dart';
import '../models/test_plan.dart';
import '../models/time_trial_lap.dart';
import '../services/practice_log_store.dart';
import '../services/stint_summary.dart';
import 'practice_log_screen.dart';

/// The Practice Log's first page: every round with stints logged against
/// it (practice and race laps), most recently driven first, the current
/// round highlighted. Tapping one opens its log.
class PracticeRoundsScreen extends StatefulWidget {
  /// The current round's name, and its live laps (what the dashboard is
  /// logging, which may be ahead of what's saved).
  final String currentRound;
  final List<PracticeLapRecord> Function() currentLaps;

  /// Opens the current round's log (the dashboard wires in its live
  /// state and its delete/clear actions).
  final Future<void> Function() openCurrentRound;

  const PracticeRoundsScreen({
    super.key,
    required this.currentRound,
    required this.currentLaps,
    required this.openCurrentRound,
  });

  @override
  State<PracticeRoundsScreen> createState() => _PracticeRoundsScreenState();
}

class _PracticeRoundsScreenState extends State<PracticeRoundsScreen> {
  List<PracticeRoundSummary>? _rounds;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final saved = await PracticeLogStore.rounds();
    if (!mounted) return;
    // The current round from its live laps; the rest as saved.
    final others = saved.where((r) => r.round != widget.currentRound).toList();
    final currentSaved = saved.where((r) => r.round == widget.currentRound).firstOrNull;
    final laps = widget.currentLaps();
    final current = laps.isEmpty
        ? null
        : PracticeRoundSummary(
            round: widget.currentRound,
            laps: laps.length,
            stints: StintSummary.fromLaps(laps).length,
            raceLaps: laps.where((l) => l.isRaceLap).length,
            bestMs: laps
                .where((l) => !l.isPitLap && l.lapTimeMs > 0)
                .map((l) => l.lapTimeMs)
                .fold<int?>(null, (a, b) => a == null || b < a ? b : a),
            lastDriven: laps.last.recordedAt,
            briefing: currentSaved?.briefing,
          );
    setState(() => _rounds = [?current, ...others]);
  }

  Future<void> _open(PracticeRoundSummary summary) async {
    if (summary.round == widget.currentRound) {
      await widget.openCurrentRound();
    } else {
      await _openPastRound(summary);
    }
    _load();
  }

  /// An earlier round's log: read from the database, and its deletes
  /// written straight back to that round.
  Future<void> _openPastRound(PracticeRoundSummary summary) async {
    final round = summary.round;
    var laps = await PracticeLogStore.loadFor(round);
    if (!mounted) return;
    final briefing = summary.briefing;
    Future<void> saveWithout(Set<DateTime> gone) async {
      laps = [
        for (final (i, lap) in laps.where((l) => !gone.contains(l.recordedAt)).indexed) lap.withLapNumber(i + 1),
      ];
      await PracticeLogStore.save(laps, round: round);
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => PracticeLogScreen(
          laps: laps,
          roundName: round,
          testPlan: briefing == null
              ? null
              : TestPlan.fromBriefing(
                  briefing,
                  // That round's fuel use, from its own laps, sizes the stints.
                  fuelPerLapPercent: StintSummary.fromLaps(laps).map((s) => s.fuelPerLapPercent).nonNulls.firstOrNull,
                  fuelMapToTest: TestPlan.fuelMapTested(laps),
                ),
          weather: briefing?.weather,
          pitStopTimeSeconds: briefing?.pitStopTimeSeconds,
          onClear: () async {
            await PracticeLogStore.clear(round: round);
            if (context.mounted) Navigator.of(context).pop();
          },
          onDeleteLap: (recordedAt) => saveWithout({recordedAt}),
          onDeleteStint: saveWithout,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rounds = _rounds;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('PRACTICE LOG')),
      body: SafeArea(
        child: rounds == null
            ? const Center(child: CircularProgressIndicator())
            : rounds.isEmpty
            ? Center(
                child: Text(
                  'No stints logged yet.\nDrive some laps in Practice or Race Mode and each round shows here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 17),
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'Every round with stints logged. Tap one to see its stints and laps.',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 15),
                  ),
                  const SizedBox(height: 12),
                  for (final r in rounds) ...[_roundCard(r), const SizedBox(height: 10)],
                ],
              ),
      ),
    );
  }

  Widget _roundCard(PracticeRoundSummary r) {
    final current = r.round == widget.currentRound;
    final calendar = LeagueCalendar.byName(r.round);
    final title = r.round.isEmpty ? 'No round picked' : r.round;
    final track = r.track;
    String date(DateTime d) => '${d.day}/${d.month}/${d.year}';
    final practiceLaps = r.laps - r.raceLaps;
    final stats = <(String, String)>[
      ('STINTS', '${r.stints}'),
      ('PRACTICE LAPS', '$practiceLaps'),
      if (r.raceLaps > 0) ('RACE LAPS', '${r.raceLaps}'),
      ('BEST LAP', r.bestMs == null ? '--' : TimeTrialLap.format(r.bestMs!)),
      if (r.lastDriven != null) ('LAST DRIVEN', date(r.lastDriven!)),
    ];
    return Material(
      color: current ? Colors.teal.shade900.withValues(alpha: 0.45) : Colors.grey.shade900,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _open(r),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: current ? Colors.teal.shade400 : Colors.white12, width: current ? 2 : 1),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900),
                          ),
                        ),
                        if (current) ...[
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(color: Colors.teal.shade400, borderRadius: BorderRadius.circular(4)),
                            child: const Text(
                              'CURRENT',
                              style: TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 1),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (track != null && !(calendar != null && r.round.endsWith(track))) ...[
                      const SizedBox(height: 2),
                      Text(track, style: TextStyle(color: Colors.grey.shade300, fontSize: 16)),
                    ],
                    if (calendar != null) ...[
                      const SizedBox(height: 2),
                      Text(calendar.details, style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
                    ],
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 22,
                      runSpacing: 8,
                      children: [
                        for (final (name, value) in stats)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(name, style: TextStyle(color: Colors.grey.shade500, fontSize: 12, letterSpacing: 1)),
                              Text(
                                value,
                                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white54, size: 30),
            ],
          ),
        ),
      ),
    );
  }
}
