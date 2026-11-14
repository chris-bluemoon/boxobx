import '../models/practice_lap_record.dart';
import '../models/race_strategy.dart';
import '../models/time_trial_lap.dart';
import 'stint_summary.dart';

/// A pit stop made in a race, worked out from the stint change around it.
class RacePitStop {
  /// Race lap (1-based within the race) the stop was made on.
  final int lap;
  final String tyreFitted;
  final double fuelAddedPercent;

  const RacePitStop({required this.lap, required this.tyreFitted, required this.fuelAddedPercent});
}

/// A planned stop next to the stop actually made for it (either can be
/// missing: a planned stop skipped, or an extra unplanned one).
class PlannedVsActualStop {
  final PlannedPitStop? planned;
  final RacePitStop? actual;

  const PlannedVsActualStop({this.planned, this.actual});

  /// Laps early (negative) or late (positive) against the plan.
  int? get lapDifference => planned == null || actual == null ? null : actual!.lap - planned!.lap;

  bool get tyreAsPlanned => planned != null && actual != null && planned!.tireCompound == actual!.tyreFitted;
}

/// One race (a run in Race Mode -- test or real), from its laps, set
/// against the saved strategy and the time-trial best.
class RaceReport {
  final int raceNumber;

  /// Every lap of the race in order, pit laps included.
  final List<PracticeLapRecord> laps;

  RaceReport._(this.raceNumber, this.laps);

  /// One report per race in [laps], newest first.
  static List<RaceReport> fromLaps(List<PracticeLapRecord> laps) {
    final byRace = <int, List<PracticeLapRecord>>{};
    for (final lap in laps) {
      final race = lap.raceNumber;
      if (race != null) byRace.putIfAbsent(race, () => []).add(lap);
    }
    final numbers = byRace.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final n in numbers) RaceReport._(n, byRace[n]!)];
  }

  DateTime get startedAt => laps.first.recordedAt;
  int get lapCount => laps.length;

  /// Sum of every lap time, pit laps included -- the race time from the
  /// first timed lap to the flag.
  int get totalTimeMs => laps.fold(0, (sum, l) => sum + l.lapTimeMs);

  /// Position at the end of the last lap that had one read.
  int? get finishingPosition => laps.reversed.map((l) => l.position).whereType<int>().firstOrNull;

  int? get bestLapMs {
    final clean = laps.where((l) => !l.isPitLap);
    return clean.isEmpty ? null : clean.map((l) => l.lapTimeMs).reduce((a, b) => a < b ? a : b);
  }

  /// The race's stints, in race order.
  List<StintSummary> get stints => StintSummary.fromLaps(laps).reversed.toList();

  String get startingTyre => laps.first.tireCompound;

  /// Average fuel used per lap, pit laps excluded.
  double? get fuelPerLapPercent {
    final used = laps.where((l) => !l.isPitLap).map((l) => l.fuelConsumedPercent).where((f) => f > 0).toList();
    return used.isEmpty ? null : used.reduce((a, b) => a + b) / used.length;
  }

  /// The stops made: one at each change of stint (a stop starts a new
  /// stint), on the first flagged pit lap there.
  List<RacePitStop> get pitStops {
    final stops = <RacePitStop>[];
    final stintList = stints;
    for (var k = 1; k < stintList.length; k++) {
      final before = stintList[k - 1];
      final after = stintList[k];
      final around = [...before.laps, ...after.laps];
      final firstPit = around.where((l) => l.isPitLap).firstOrNull;
      final stopLap = firstPit ?? after.laps.first;
      stops.add(
        RacePitStop(
          lap: laps.indexOf(stopLap) + 1,
          tyreFitted: after.tyreCompound,
          fuelAddedPercent: _fuelAddedAround(laps.indexOf(before.laps.last), laps.indexOf(after.laps.first)),
        ),
      );
    }
    return stops;
  }

  /// Fuel increases between lap [from] and lap [to] (indices into laps):
  /// within those laps (refuelled mid-lap) and between them.
  double _fuelAddedAround(int from, int to) {
    var added = 0.0;
    for (var i = from; i <= to; i++) {
      final lap = laps[i];
      if (lap.fuelPercentAtLapEnd > lap.fuelPercentAtLapStart) {
        added += lap.fuelPercentAtLapEnd - lap.fuelPercentAtLapStart;
      }
      if (i > from && lap.fuelPercentAtLapStart > laps[i - 1].fuelPercentAtLapEnd) {
        added += lap.fuelPercentAtLapStart - laps[i - 1].fuelPercentAtLapEnd;
      }
    }
    return added;
  }

  /// Planned stops matched to actual ones in order (stop 1 with stop 1,
  /// ...), with any extras on either side left unmatched.
  List<PlannedVsActualStop> comparedWith(RaceStrategy strategy) {
    final planned = strategy.pitStops;
    final actual = pitStops;
    final count = planned.length > actual.length ? planned.length : actual.length;
    return [
      for (var i = 0; i < count; i++)
        PlannedVsActualStop(
          planned: i < planned.length ? planned[i] : null,
          actual: i < actual.length ? actual[i] : null,
        ),
    ];
  }

  /// Average gap of clean laps to [timeTrialBest] (seconds), overall or
  /// for one stint.
  static double? averageGapSeconds(Iterable<PracticeLapRecord> laps, TimeTrialLap? timeTrialBest) {
    if (timeTrialBest == null) return null;
    final clean = laps.where((l) => !l.isPitLap).toList();
    if (clean.isEmpty) return null;
    final gaps = clean.map((l) => (l.lapTimeMs - timeTrialBest.lapTimeMs) / 1000);
    return gaps.reduce((a, b) => a + b) / clean.length;
  }

  /// e.g. "42:17.512" or "1:02:17.512".
  static String formatTotal(int ms) {
    final hours = ms ~/ 3600000;
    final minutes = (ms % 3600000) ~/ 60000;
    final seconds = ((ms % 60000) / 1000).toStringAsFixed(3).padLeft(6, '0');
    return hours > 0 ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds' : '$minutes:$seconds';
  }
}
