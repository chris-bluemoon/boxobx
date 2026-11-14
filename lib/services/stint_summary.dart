import '../models/practice_lap_record.dart';

/// Results of one stint (a run on one set of tyres and one fuel load),
/// from its logged laps -- what lets the driver run tyres and fuel to
/// their limit and read off how long each lasts.
///
/// Pit laps are left out of every figure (they include the stop).
class StintSummary {
  final int stintNumber;
  final bool isRace;

  /// Every lap in the stint, oldest first (including pit laps).
  final List<PracticeLapRecord> laps;

  StintSummary._(this.stintNumber, this.isRace, this.laps);

  /// Groups laps into stints, newest stint first. Laps logged before
  /// stints existed (stintNumber 0) form one group of their own.
  static List<StintSummary> fromLaps(List<PracticeLapRecord> laps) {
    final byStint = <int, List<PracticeLapRecord>>{};
    for (final lap in laps) {
      byStint.putIfAbsent(lap.stintNumber, () => []).add(lap);
    }
    final numbers = byStint.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final n in numbers) StintSummary._(n, byStint[n]!.any((l) => l.isRaceLap), byStint[n]!)];
  }

  /// The planned test the driver ran this stint for, if any.
  int? get testNumber => laps.first.testNumber;

  List<PracticeLapRecord> get _clean => laps.where((l) => !l.isPitLap).toList();

  int get lapCount => _clean.length;

  /// Fuel when the stint began (percent of tank).
  double get startFuelPercent => laps.first.fuelPercentAtLapStart;

  /// The stint's tyre compound (the most common one across its laps,
  /// in case the picker was corrected partway through).
  String get tyreCompound {
    final counts = <String, int>{};
    for (final lap in laps) {
      counts[lap.tireCompound] = (counts[lap.tireCompound] ?? 0) + 1;
    }
    return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  /// GT7's short code for the compound, as on the in-game HUD.
  static String compoundCode(String compound) => switch (compound) {
    'Racing Soft' => 'RS',
    'Racing Medium' => 'RM',
    'Racing Hard' => 'RH',
    'Intermediate' => 'IM',
    'Heavy Wet' => 'W',
    _ => compound,
  };

  /// e.g. "Round 5 Testing - Stint 1 - Fuel 100%, Tyre RS".
  String label(String? roundName) {
    if (stintNumber == 0) return '${roundName ?? 'Practice'} - Earlier laps (before stints)';
    final round = roundName ?? 'Practice';
    final test = testNumber == null ? '' : ' (Test $testNumber)';
    return '$round ${isRace ? 'Race' : 'Testing'} - Stint $stintNumber$test - '
        'Fuel ${startFuelPercent.toStringAsFixed(0)}%, Tyre ${compoundCode(tyreCompound)}';
  }

  double? get averageLapMs {
    final clean = _clean;
    if (clean.isEmpty) return null;
    return clean.map((l) => l.lapTimeMs).reduce((a, b) => a + b) / clean.length;
  }

  /// Average fuel used per lap (percent of tank).
  double? get fuelPerLapPercent {
    final used = _clean.map((l) => l.fuelConsumedPercent).where((f) => f > 0).toList();
    if (used.isEmpty) return null;
    return used.reduce((a, b) => a + b) / used.length;
  }

  /// How many laps the stint's starting fuel lasts at that rate.
  double? get projectedFuelLaps {
    final perLap = fuelPerLapPercent;
    return perLap == null || perLap <= 0 ? null : startFuelPercent / perLap;
  }

  /// Average tyre wear per lap (percent of grip lost), from the HUD
  /// readings at the first and last laps that have one. Needs two.
  double? get tyreWearPerLapPercent {
    final readings = [
      for (var i = 0; i < _clean.length; i++)
        if (_clean[i].tireWearPercent != null) (i, _clean[i].tireWearPercent!),
    ];
    if (readings.length < 2) return null;
    final (firstIndex, firstWear) = readings.first;
    final (lastIndex, lastWear) = readings.last;
    if (lastIndex == firstIndex) return null;
    final perLap = (firstWear - lastWear) / (lastIndex - firstIndex);
    return perLap > 0 ? perLap : null;
  }

  /// Latest remaining-grip reading in the stint, if any.
  double? get latestTyreWearPercent {
    for (final lap in _clean.reversed) {
      if (lap.tireWearPercent != null) return lap.tireWearPercent;
    }
    return null;
  }

  /// Laps a fresh set would last to fully worn at this wear rate.
  double? get projectedTyreLaps {
    final perLap = tyreWearPerLapPercent;
    return perLap == null ? null : 100 / perLap;
  }

  /// Lap-time drop-off: average of the last 3 laps minus the first 3
  /// (milliseconds; positive = slowing). Needs at least 4 laps.
  double? get dropOffMs {
    final clean = _clean;
    if (clean.length < 4) return null;
    final n = clean.length >= 6 ? 3 : clean.length ~/ 2;
    double avg(Iterable<PracticeLapRecord> l) => l.map((x) => x.lapTimeMs).reduce((a, b) => a + b) / n;
    return avg(clean.sublist(clean.length - n)) - avg(clean.take(n));
  }
}
