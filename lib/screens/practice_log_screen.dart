import 'package:flutter/material.dart';

import '../models/practice_lap_record.dart';
import '../services/stint_summary.dart';
import '../services/test_plan_tracker.dart';
import '../models/test_plan.dart';

/// Shows every logged practice lap (lap time, tire compound, fuel
/// start/end, and tire wear % auto-captured from the laptop OCR
/// relay's HUD reading at the moment each lap completes -- see
/// PracticeLapLogger.currentTireWearPercent) for whichever
/// round is currently active, plus simple per-compound averages so the
/// driver can see at a glance how consistent/fast and how worn each
/// tire has been -- answers "how can I see how many laps I have
/// practiced" and "can each lap be shown with a lap time, tyre type,
/// fuel level" (now also tire wear %, per the stint-planning
/// methodology: watch for the wear "cliff" around 50%/20% remaining).
class PracticeLogScreen extends StatefulWidget {
  final List<PracticeLapRecord> laps;
  final VoidCallback onClear;

  /// Called with the recordedAt timestamp of a single lap the driver
  /// wants removed (e.g. a spin, a lap interrupted by traffic) -- lets
  /// one bad lap be deleted without clearing the whole practice log.
  final ValueChanged<DateTime> onDeleteLap;

  /// The saved round's name (e.g. "Round 5"), used in stint labels.
  final String? roundName;

  /// The round's practice test plan, shown with each test's status.
  final TestPlan? testPlan;

  /// The test being run right now, if any (shown as in progress).
  final int? activeTestNumber;

  const PracticeLogScreen({
    super.key,
    required this.laps,
    this.roundName,
    this.testPlan,
    this.activeTestNumber,
    required this.onClear,
    required this.onDeleteLap,
  });

  @override
  State<PracticeLogScreen> createState() => _PracticeLogScreenState();
}

class _PracticeLogScreenState extends State<PracticeLogScreen> {
  late List<PracticeLapRecord> _laps;

  @override
  void initState() {
    super.initState();
    // widget.laps comes from PracticeLapLogger.laps, which returns
    // List.unmodifiable(...) -- assigning it directly here (rather than
    // copying into a genuinely mutable List) meant _deleteLap's
    // _laps.removeWhere(...) below threw an UnsupportedError at
    // runtime and silently failed, so swiping/long-pressing/tapping
    // the delete button never actually removed the row from view.
    _laps = List.of(widget.laps);
  }

  Future<bool> _confirmDeleteLap(PracticeLapRecord lap) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: Text('Delete lap ${lap.lapNumber}?', style: const TextStyle(color: Colors.white)),
        content: Text(
          'Removes this one lap (${lap.formattedLapTime}) from the practice log. Remaining laps will be renumbered. This cannot be undone.',
          style: TextStyle(color: Colors.grey.shade400),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  void _deleteLap(PracticeLapRecord lap) {
    setState(() => _laps.removeWhere((l) => l.recordedAt == lap.recordedAt));
    // Renumber remaining laps sequentially, same logic as
    // PracticeLapLogger.removeLap -- keeps the widget's local list
    // consistent with the persisted/live version after deletion.
    for (var i = 0; i < _laps.length; i++) {
      if (_laps[i].lapNumber != i + 1) _laps[i] = _laps[i].withLapNumber(i + 1);
    }
    widget.onDeleteLap(lap.recordedAt);
  }

  @override
  Widget build(BuildContext context) {
    final laps = _laps;
    final byCompound = <String, List<PracticeLapRecord>>{};
    // Pit laps would skew the per-compound lap-time and fuel averages.
    for (final lap in laps.where((l) => !l.isPitLap)) {
      byCompound.putIfAbsent(lap.tireCompound, () => []).add(lap);
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('PRACTICE LOG (${laps.length} LAPS)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear practice log',
            onPressed: laps.isEmpty
                ? null
                : () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        backgroundColor: Colors.grey.shade900,
                        title: const Text('Clear practice log?', style: TextStyle(color: Colors.white)),
                        content: Text(
                          'This deletes all ${laps.length} logged laps for the current round. This cannot be undone.',
                          style: TextStyle(color: Colors.grey.shade400),
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Clear', style: TextStyle(color: Colors.redAccent)),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) widget.onClear();
                  },
          ),
        ],
      ),
      body: SafeArea(
        child: laps.isEmpty
            ? Center(
                child: Text(
                  'No practice laps logged yet.\nDrive a few laps with telemetry engaged.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade500),
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (byCompound.length > 1) ...[
                    _sectionLabel('AVERAGE BY COMPOUND'),
                    const SizedBox(height: 8),
                    for (final entry in byCompound.entries) _compoundSummaryRow(entry.key, entry.value),
                    const SizedBox(height: 20),
                  ],
                  if (widget.testPlan != null && widget.testPlan!.stints.isNotEmpty) ...[
                    _sectionLabel('TEST PLAN'),
                    const SizedBox(height: 8),
                    _testPlanCard(widget.testPlan!, laps),
                    const SizedBox(height: 20),
                  ],
                  _sectionLabel('STINTS (swipe a lap left or long-press to delete it)'),
                  const SizedBox(height: 8),
                  for (final stint in StintSummary.fromLaps(laps)) ...[
                    _stintCard(stint),
                    const SizedBox(height: 8),
                    for (final lap in stint.laps.reversed) _lapRow(lap),
                    const SizedBox(height: 16),
                  ],
                ],
              ),
      ),
    );
  }

  /// The test plan: each planned stint, what it's for, and whether it's
  /// done (with the logged stint that did it), running, or still to do.
  Widget _testPlanCard(TestPlan plan, List<PracticeLapRecord> laps) {
    final progress = TestPlanTracker.progress(plan, laps, activeTestNumber: widget.activeTestNumber);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.grey.shade900, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, planned) in plan.stints.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    switch (progress.statuses[i]) {
                      TestStatus.done => Icons.check_circle,
                      TestStatus.inProgress => Icons.play_circle,
                      TestStatus.toDo => Icons.radio_button_unchecked,
                    },
                    size: 18,
                    color: switch (progress.statuses[i]) {
                      TestStatus.done => Colors.greenAccent,
                      TestStatus.inProgress => Colors.lightBlueAccent,
                      TestStatus.toDo => Colors.grey.shade600,
                    },
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Test ${planned.number}: ${progress.targetFor(planned)}',
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          progress.matchedStints[i] == null
                              ? planned.purpose
                              : '${planned.purpose} -- stint ${progress.matchedStints[i]!.stintNumber}',
                          style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          Text(
            'Start a test from the dashboard\'s TEST chip (long-press to pick any test). Only stints '
            'started as a test count. Long stints also end if fuel drops to 5% or lap times fall 1.5s '
            'off the stint best.',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 10),
          ),
        ],
      ),
    );
  }

  /// One stint's header: its label and how the tyres and fuel held up.
  Widget _stintCard(StintSummary stint) {
    String laps(double? v) => v == null ? '--' : '${v.toStringAsFixed(1)} laps';
    String lapTime(double? ms) {
      if (ms == null) return '--';
      final minutes = ms ~/ 60000;
      return '$minutes:${((ms % 60000) / 1000).toStringAsFixed(3).padLeft(6, '0')}';
    }

    final fuel = stint.fuelPerLapPercent;
    final wear = stint.tyreWearPerLapPercent;
    final dropOff = stint.dropOffMs;
    final stats = <(String, String)>[
      ('Laps', '${stint.lapCount}'),
      ('Avg lap', lapTime(stint.averageLapMs)),
      ('Fuel/lap', fuel == null ? '--' : '${fuel.toStringAsFixed(2)}%'),
      ('Fuel lasts', laps(stint.projectedFuelLaps)),
      ('Wear/lap', wear == null ? '--' : '${wear.toStringAsFixed(1)}%'),
      ('Tyres last', laps(stint.projectedTyreLaps)),
      ('Drop-off', dropOff == null ? '--' : '${dropOff >= 0 ? '+' : ''}${(dropOff / 1000).toStringAsFixed(2)}s'),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: stint.isRace ? Colors.red.shade900.withValues(alpha: 0.35) : Colors.teal.shade900.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: stint.isRace ? Colors.red.shade700 : Colors.teal.shade700),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            stint.label(widget.roundName),
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              for (final (name, value) in stats)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: TextStyle(color: Colors.grey.shade500, fontSize: 10)),
                    Text(value, style: const TextStyle(color: Colors.white, fontSize: 13)),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
        text,
        style: TextStyle(color: Colors.grey.shade400, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 1.0),
      );

  Widget _compoundSummaryRow(String compound, List<PracticeLapRecord> compoundLaps) {
    final avgLapMs = compoundLaps.map((l) => l.lapTimeMs).reduce((a, b) => a + b) / compoundLaps.length;
    final avgFuel = compoundLaps.map((l) => l.fuelConsumedPercent).reduce((a, b) => a + b) / compoundLaps.length;
    final avgMinutes = avgLapMs ~/ 60000;
    final avgSeconds = (avgLapMs % 60000) / 1000;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(compound, style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
          Expanded(
            child: Text(
              'avg $avgMinutes:${avgSeconds.toStringAsFixed(3).padLeft(6, '0')}',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              'avg ${avgFuel.toStringAsFixed(2)}%/lap',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              '${compoundLaps.length} laps',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _lapRow(PracticeLapRecord lap) {
    return Dismissible(
      key: ValueKey(lap.recordedAt),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDeleteLap(lap),
      onDismissed: (_) => _deleteLap(lap),
      background: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.centerRight,
        decoration: BoxDecoration(
          color: Colors.red.shade900,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      child: InkWell(
        onLongPress: () async {
          if (await _confirmDeleteLap(lap)) _deleteLap(lap);
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.grey.shade900,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.purple.shade900,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  lap.isPitLap ? 'L${lap.lapNumber} PIT' : 'L${lap.lapNumber}',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: Text(
                  lap.formattedLapTime,
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(lap.tireCompound, style: TextStyle(color: Colors.grey.shade300, fontSize: 12)),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  '${lap.fuelPercentAtLapStart.toStringAsFixed(1)}% → ${lap.fuelPercentAtLapEnd.toStringAsFixed(1)}%',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
                ),
              ),
              Expanded(
                child: lap.tireWearPercent != null
                    ? Text(
                        'wear ${lap.tireWearPercent!.toStringAsFixed(0)}%',
                        style: const TextStyle(color: Colors.orangeAccent, fontSize: 11, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.right,
                      )
                    : Text(
                        // Read-only -- tire wear is now auto-captured
                        // from the laptop OCR relay's HUD reading at
                        // the moment each lap completes (see
                        // PracticeLapLogger.currentTireWearPercent),
                        // not entered manually. Null here just means
                        // the relay wasn't running/hadn't produced a
                        // confident reading yet when this particular
                        // lap completed.
                        'wear --',
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                        textAlign: TextAlign.right,
                      ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                color: Colors.grey.shade600,
                tooltip: 'Delete this lap',
                onPressed: () async {
                  if (await _confirmDeleteLap(lap)) _deleteLap(lap);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
