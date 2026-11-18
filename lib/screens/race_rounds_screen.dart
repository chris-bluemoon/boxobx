import 'package:flutter/material.dart';

import '../models/league_calendar.dart';
import '../models/practice_lap_record.dart';
import '../models/race_strategy.dart';
import '../models/time_trial_lap.dart';
import '../services/driver_profile.dart';
import '../services/practice_log_store.dart';
import '../services/race_report.dart';
import '../services/saved_briefing_store.dart';
import '../services/time_trial_store.dart';
import 'race_reports_screen.dart';

/// Race Reports' first page: every round with races run in Race Mode
/// (test races and the real one), most recently raced first, the
/// current round highlighted. Tapping one lists its races.
class RaceRoundsScreen extends StatefulWidget {
  /// The current round, with its live laps, saved strategy and time-trial
  /// best (what the dashboard holds, which may be ahead of what's saved).
  final String currentRound;
  final List<PracticeLapRecord> Function() currentLaps;
  final RaceStrategy? currentStrategy;
  final TimeTrialLap? currentTimeTrialBest;

  /// Deletes laps from the current round's live log (other rounds are
  /// edited in PracticeLogStore directly).
  final Future<void> Function(Set<DateTime> recordedAts)? deleteCurrentLaps;

  const RaceRoundsScreen({
    super.key,
    required this.currentRound,
    required this.currentLaps,
    this.currentStrategy,
    this.currentTimeTrialBest,
    this.deleteCurrentLaps,
  });

  @override
  State<RaceRoundsScreen> createState() => _RaceRoundsScreenState();
}

/// A round's races, for the list.
class _RaceRound {
  final String round;
  final String? track;
  final List<RaceReport> races;

  _RaceRound(this.round, this.track, this.races);

  int? get bestFinish =>
      races.map((r) => r.finishingPosition).whereType<int>().fold<int?>(null, (a, b) => a == null || b < a ? b : a);
  DateTime get lastRaced => races.map((r) => r.startedAt).reduce((a, b) => b.isAfter(a) ? b : a);
}

class _RaceRoundsScreenState extends State<RaceRoundsScreen> {
  List<_RaceRound>? _rounds;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rounds = <_RaceRound>[];
    final currentRaces = RaceReport.fromLaps(widget.currentLaps());
    if (currentRaces.isNotEmpty) {
      rounds.add(_RaceRound(widget.currentRound, LeagueCalendar.byName(widget.currentRound)?.gt7Track, currentRaces));
    }
    for (final summary in await PracticeLogStore.rounds()) {
      if (summary.round == widget.currentRound || summary.raceLaps == 0) continue;
      final races = RaceReport.fromLaps(await PracticeLogStore.loadFor(summary.round));
      if (races.isNotEmpty) rounds.add(_RaceRound(summary.round, summary.track, races));
    }
    if (!mounted) return;
    setState(() => _rounds = rounds);
  }

  Future<void> _open(_RaceRound r) async {
    final current = r.round == widget.currentRound;
    RaceStrategy? strategy = widget.currentStrategy;
    TimeTrialLap? ttBest = widget.currentTimeTrialBest;
    var laps = widget.currentLaps();
    if (!current) {
      strategy = (await SavedBriefingStore.briefingFor(r.round))?.$2;
      ttBest = TimeTrialLap.best(await TimeTrialStore.loadFor(r.round));
      laps = await PracticeLogStore.loadFor(r.round);
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RaceReportsScreen(
          laps: laps,
          strategy: strategy,
          timeTrialBest: ttBest,
          roundName: r.round.isEmpty ? null : r.round,
          onDeleteRace: current
              ? widget.deleteCurrentLaps
              : (gone) async {
                  final all = await PracticeLogStore.loadFor(r.round);
                  await PracticeLogStore.save([for (final l in all) if (!gone.contains(l.recordedAt)) l], round: r.round);
                },
        ),
      ),
    );
    // A race may have been deleted.
    _load();
  }

  /// What Boxington has learnt about the driver (see DriverProfile).
  Future<void> _showProfile() async {
    final profile = await DriverProfile.load();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: const Text('WHAT BOXINGTON KNOWS ABOUT YOU'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final line in profile.lines())
                Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(line)),
              if (profile.diary.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('RACE DIARY', style: TextStyle(color: Colors.grey.shade400, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                for (final race in profile.diary.take(10))
                  Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(race.describe())),
              ],
              const SizedBox(height: 8),
              Text(
                'Built from every lap you log, in every round. Spins are counted from 18 Nov 2026.',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('CLOSE'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rounds = _rounds;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('RACE REPORTS'),
        actions: [
          IconButton(
            tooltip: 'What Boxington knows about you',
            icon: const Icon(Icons.psychology),
            onPressed: _showProfile,
          ),
        ],
      ),
      body: SafeArea(
        child: rounds == null
            ? const Center(child: CircularProgressIndicator())
            : rounds.isEmpty
            ? Center(
                child: Text(
                  'No races yet.\nEvery race run in Race Mode (test or real) shows here under its round.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 17),
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'Every round with races run. Tap one to see its race reports.',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 15),
                  ),
                  const SizedBox(height: 12),
                  for (final r in rounds) ...[_roundCard(r), const SizedBox(height: 10)],
                ],
              ),
      ),
    );
  }

  Widget _roundCard(_RaceRound r) {
    final current = r.round == widget.currentRound;
    final calendar = LeagueCalendar.byName(r.round);
    final track = r.track;
    String date(DateTime d) => '${d.day}/${d.month}/${d.year}';
    final best = r.bestFinish;
    final stats = <(String, String)>[
      ('RACES', '${r.races.length}'),
      ('BEST FINISH', best == null ? '--' : 'P$best'),
      ('LAST RACED', date(r.lastRaced)),
    ];
    return Material(
      color: current ? Colors.red.shade900.withValues(alpha: 0.4) : Colors.grey.shade900,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _open(r),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: current ? Colors.red.shade400 : Colors.white12, width: current ? 2 : 1),
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
                            r.round.isEmpty ? 'No round picked' : r.round,
                            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900),
                          ),
                        ),
                        if (current) ...[
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(color: Colors.red.shade400, borderRadius: BorderRadius.circular(4)),
                            child: const Text(
                              'CURRENT',
                              style: TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 1),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (track != null && !r.round.endsWith(track)) ...[
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
