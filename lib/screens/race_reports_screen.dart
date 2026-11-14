import 'package:flutter/material.dart';

import '../models/practice_lap_record.dart';
import '../models/race_strategy.dart';
import '../models/time_trial_lap.dart';
import '../services/race_report.dart';
import '../services/stint_summary.dart';

String _date(DateTime t) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${t.day} ${months[t.month - 1]} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

String _gap(double? seconds) => seconds == null ? '--' : '${seconds >= 0 ? '+' : ''}${seconds.toStringAsFixed(2)}s';

String _short(String compound) => compound.replaceFirst('Racing ', '');

/// Every race run in Race Mode this round (test races and the real one),
/// newest first; tap one for its report.
class RaceReportsScreen extends StatelessWidget {
  final List<PracticeLapRecord> laps;
  final RaceStrategy? strategy;
  final TimeTrialLap? timeTrialBest;
  final String? roundName;

  const RaceReportsScreen({super.key, required this.laps, this.strategy, this.timeTrialBest, this.roundName});

  @override
  Widget build(BuildContext context) {
    final reports = RaceReport.fromLaps(laps);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('RACE REPORTS${roundName == null ? '' : ' · ${roundName!.toUpperCase()}'}'),
      ),
      body: reports.isEmpty
          ? Center(
              child: Text(
                'No races yet -- every run in Race Mode (test or real) appears here.',
                style: TextStyle(color: Colors.grey.shade500),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final report in reports)
                  Card(
                    color: Colors.grey.shade900,
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      title: Text(
                        'Race ${report.raceNumber} · ${_date(report.startedAt)}',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      subtitle: Text(
                        '${report.lapCount} laps · ${RaceReport.formatTotal(report.totalTimeMs)}'
                        '${report.finishingPosition == null ? '' : ' · P${report.finishingPosition}'}'
                        ' · ${report.pitStops.length} stop${report.pitStops.length == 1 ? '' : 's'}',
                        style: TextStyle(color: Colors.grey.shade400),
                      ),
                      trailing: const Icon(Icons.chevron_right, color: Colors.white),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              RaceReportScreen(report: report, strategy: strategy, timeTrialBest: timeTrialBest),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// One race: result, plan against actual, stints, pit stops and pace.
class RaceReportScreen extends StatelessWidget {
  final RaceReport report;
  final RaceStrategy? strategy;
  final TimeTrialLap? timeTrialBest;

  const RaceReportScreen({super.key, required this.report, this.strategy, this.timeTrialBest});

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Text(
      title,
      style: TextStyle(color: Colors.grey.shade400, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 1.0),
    ),
  );

  Widget _box(List<Widget> children) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: Colors.grey.shade900, borderRadius: BorderRadius.circular(8)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
  );

  Widget _stats(List<(String, String)> stats) => Wrap(
    spacing: 22,
    runSpacing: 10,
    children: [
      for (final (name, value) in stats)
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
            Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final white = const TextStyle(color: Colors.white, fontSize: 13);
    final grey = TextStyle(color: Colors.grey.shade400, fontSize: 13);
    final best = report.bestLapMs;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('RACE ${report.raceNumber} · ${_date(report.startedAt)}'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('RESULT'),
          _box([
            _stats([
              ('Total time', RaceReport.formatTotal(report.totalTimeMs)),
              ('Finished', report.finishingPosition == null ? '--' : 'P${report.finishingPosition}'),
              ('Laps', '${report.lapCount}'),
              ('Best lap', best == null ? '--' : TimeTrialLap.format(best)),
              ('Avg vs TT best', _gap(RaceReport.averageGapSeconds(report.laps, timeTrialBest))),
            ]),
          ]),
          _section('PLAN VS ACTUAL'),
          if (strategy == null)
            _box([Text('No saved strategy to compare with -- save one on the strategy screen.', style: grey)])
          else
            _box([
              Text(
                'Start: ${_short(strategy!.startingTireCompound)} planned, ${_short(report.startingTyre)} used'
                '${strategy!.startingTireCompound == report.startingTyre ? ' ✓' : ''}',
                style: white,
              ),
              const SizedBox(height: 4),
              Text(
                'Fuel per lap: ${strategy!.assumedPercentPerLap.toStringAsFixed(2)}% planned, '
                '${report.fuelPerLapPercent == null ? '--' : '${report.fuelPerLapPercent!.toStringAsFixed(2)}%'} actual',
                style: white,
              ),
              const SizedBox(height: 10),
              for (final (i, pair) in report.comparedWith(strategy!).indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      SizedBox(width: 64, child: Text('Stop ${i + 1}', style: grey)),
                      Expanded(
                        child: Text(
                          pair.planned == null
                              ? 'not planned'
                              : 'plan L${pair.planned!.lap} ${_short(pair.planned!.tireCompound)}',
                          style: white,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          pair.actual == null
                              ? 'not made'
                              : 'made L${pair.actual!.lap} ${_short(pair.actual!.tyreFitted)}',
                          style: white,
                        ),
                      ),
                      SizedBox(
                        width: 120,
                        child: Text(
                          switch (pair.lapDifference) {
                            null => '',
                            0 => 'on time${pair.tyreAsPlanned ? ' ✓' : ', other tyre'}',
                            final d =>
                              '${d.abs()} lap${d.abs() == 1 ? '' : 's'} ${d < 0 ? 'early' : 'late'}'
                                  '${pair.tyreAsPlanned ? '' : ', other tyre'}',
                          },
                          style: grey,
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                ),
            ]),
          _section('STINTS'),
          for (final (i, stint) in report.stints.indexed) ...[
            _box([
              Text(
                'Stint ${i + 1}: ${_short(stint.tyreCompound)} · ${stint.lapCount} laps',
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              _stats([
                (
                  'Fuel/lap',
                  stint.fuelPerLapPercent == null ? '--' : '${stint.fuelPerLapPercent!.toStringAsFixed(2)}%',
                ),
                (
                  'Wear/lap',
                  stint.tyreWearPerLapPercent == null ? '--' : '${stint.tyreWearPerLapPercent!.toStringAsFixed(1)}%',
                ),
                ('Drop-off', stint.dropOffMs == null ? '--' : _gap(stint.dropOffMs! / 1000)),
                ('Avg vs TT best', _gap(RaceReport.averageGapSeconds(stint.laps, timeTrialBest))),
              ]),
            ]),
            const SizedBox(height: 8),
          ],
          _section('PIT STOPS'),
          _box([
            if (report.pitStops.isEmpty) Text('No stops', style: grey),
            for (final stop in report.pitStops)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'Lap ${stop.lap}: ${_short(stop.tyreFitted)}'
                  '${stop.fuelAddedPercent >= 0.5 ? ', +${stop.fuelAddedPercent.toStringAsFixed(0)}% fuel' : ''}',
                  style: white,
                ),
              ),
          ]),
          _section('LAPS'),
          _box([
            for (final (i, lap) in report.laps.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    SizedBox(width: 48, child: Text('L${i + 1}', style: grey)),
                    SizedBox(width: 100, child: Text(TimeTrialLap.format(lap.lapTimeMs), style: white)),
                    SizedBox(width: 56, child: Text(lap.position == null ? '' : 'P${lap.position}', style: grey)),
                    Expanded(
                      child: Text(
                        timeTrialBest == null ? '' : _gap((lap.lapTimeMs - timeTrialBest!.lapTimeMs) / 1000),
                        style: grey,
                      ),
                    ),
                    Text(
                      lap.isPitLap ? 'PIT' : StintSummary.compoundCode(lap.tireCompound),
                      style: TextStyle(color: lap.isPitLap ? Colors.amberAccent : Colors.grey.shade500, fontSize: 12),
                    ),
                  ],
                ),
              ),
          ]),
        ],
      ),
    );
  }
}
