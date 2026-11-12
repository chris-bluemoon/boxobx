import 'package:flutter/material.dart';

import '../models/practice_lap_record.dart';
import '../models/pit_stop_time_record.dart';
import '../services/practice_log_store.dart';
import '../services/shift_aware_fuel_calculator.dart';

/// Shows every logged practice lap (lap time, tire compound, fuel
/// start/end, and optional manually-logged tire wear %) for whichever
/// round is currently active, plus simple per-compound averages so the
/// driver can see at a glance how consistent/fast and how worn each
/// tire has been -- answers "how can I see how many laps I have
/// practiced" and "can each lap be shown with a lap time, tyre type,
/// fuel level" (now also tire wear %, per the stint-planning
/// methodology: watch for the wear "cliff" around 50%/20% remaining).
class PracticeLogScreen extends StatefulWidget {
  final List<PracticeLapRecord> laps;
  final List<PitStopTimeRecord> pitStopTimeRecords;
  final VoidCallback onClear;

  /// Called with the recordedAt timestamp of a single lap the driver
  /// wants removed (e.g. a spin, a lap interrupted by traffic) -- lets
  /// one bad lap be deleted without clearing the whole practice log.
  final ValueChanged<DateTime> onDeleteLap;

  const PracticeLogScreen({
    super.key,
    required this.laps,
    this.pitStopTimeRecords = const [],
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

  Future<void> _logTireWear(PracticeLapRecord lap) async {
    final controller = TextEditingController();
    final value = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: Text('Tire wear % for lap ${lap.lapNumber}', style: const TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(hintText: 'e.g. 62 (read off GT7\'s pause-menu tire display)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, double.tryParse(controller.text.trim())),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (value == null) return;

    final index = _laps.indexWhere((l) => l.lapNumber == lap.lapNumber);
    if (index == -1) return;
    setState(() => _laps[index] = _laps[index].withTireWearPercent(value));
    await PracticeLogStore.save(_laps);
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
    for (final lap in laps) {
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
                  if (widget.pitStopTimeRecords.isNotEmpty) ...[
                    _sectionLabel('PIT STOP TIME LOSS'),
                    const SizedBox(height: 8),
                    _pitStopSummary(widget.pitStopTimeRecords),
                    const SizedBox(height: 20),
                  ],
                  if (laps.any((l) => l.totalShiftCount > 0)) ...[
                    _sectionLabel('SHIFT QUALITY'),
                    const SizedBox(height: 8),
                    _shiftQualitySummary(laps),
                    const SizedBox(height: 20),
                  ],
                  if (byCompound.length > 1) ...[
                    _sectionLabel('AVERAGE BY COMPOUND'),
                    const SizedBox(height: 8),
                    for (final entry in byCompound.entries) _compoundSummaryRow(entry.key, entry.value),
                    const SizedBox(height: 20),
                  ],
                  _sectionLabel('ALL LAPS (tap to log tire wear %, swipe left or long-press to delete)'),
                  const SizedBox(height: 8),
                  for (final lap in laps.reversed) _lapRow(lap),
                ],
              ),
      ),
    );
  }

  /// Session-level roll-up: total short-shifts/over-revs across every
  /// logged lap, and how many of those laps were "clean enough" to
  /// trust for fuel-per-lap prediction (see ShiftAwareFuelCalculator) --
  /// answers "how much short-shifting/over-revving happened" at a
  /// glance, without needing to scan every individual lap row.
  Widget _shiftQualitySummary(List<PracticeLapRecord> laps) {
    final totalShort = laps.fold<int>(0, (sum, l) => sum + l.shortShiftCount);
    final totalOverRev = laps.fold<int>(0, (sum, l) => sum + l.overRevShiftCount);
    final totalGood = laps.fold<int>(0, (sum, l) => sum + l.goodShiftCount);
    final cleanLapCount = ShiftAwareFuelCalculator.cleanLapCount(laps);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.grey.shade900, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '$cleanLapCount/${laps.length} laps clean enough to trust for fuel prediction',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '$totalGood good shifts, $totalShort short-shifts, $totalOverRev over-revs across all logged laps',
            style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
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

  Widget _pitStopSummary(List<PitStopTimeRecord> records) {
    final avg = records.map((r) => r.totalTimeLossSeconds).reduce((a, b) => a + b) / records.length;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.grey.shade900, borderRadius: BorderRadius.circular(8)),
      child: Row(
        children: [
          Text(
            '${records.length} stop${records.length == 1 ? '' : 's'} logged',
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
          const Spacer(),
          Text(
            'avg ${avg.toStringAsFixed(1)}s loss',
            style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// Shows this lap's shift-quality breakdown (short-shifts/over-revs,
  /// the two habits that burn more fuel than a clean shift for the
  /// same distance covered) -- a quick color-coded cue, not just a
  /// raw ratio, so a glance down the lap list makes it obvious which
  /// laps were clean vs. which had a rough shifting pattern that
  /// shouldn't be trusted as hard for fuel-per-lap prediction.
  Widget _shiftQualityBadge(PracticeLapRecord lap) {
    if (lap.totalShiftCount == 0) {
      return Text('no shifts', style: TextStyle(color: Colors.grey.shade600, fontSize: 10), textAlign: TextAlign.right);
    }
    final ratio = lap.cleanShiftRatio!;
    final color = ratio >= 0.9
        ? Colors.greenAccent
        : ratio >= 0.7
            ? Colors.orangeAccent
            : Colors.redAccent;
    return Text(
      '${lap.shortShiftCount} short / ${lap.overRevShiftCount} over-rev '
      '(${(ratio * 100).toStringAsFixed(0)}% clean)',
      style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
      textAlign: TextAlign.right,
      overflow: TextOverflow.ellipsis,
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
        onTap: () => _logTireWear(lap),
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
                child: Text('L${lap.lapNumber}', style: const TextStyle(color: Colors.white, fontSize: 12)),
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
                        '+ wear',
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                        textAlign: TextAlign.right,
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(child: _shiftQualityBadge(lap)),
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
