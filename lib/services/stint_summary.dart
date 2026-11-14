import 'dart:math' as math;

import '../models/practice_lap_record.dart';

/// Where a stint's tyres went off: the first lap of a sustained loss
/// of pace against the stint's peak.
class TyreDropOff {
  /// The lap (PracticeLapRecord.lapNumber) the pace fell away from.
  final int fromLapNumber;

  /// How many counted laps the tyres held their pace for before it.
  final int lapsBeforeDropOff;

  /// Remaining grip at the start of that lap (the previous lap's
  /// reading), if logged.
  final double? wearPercentAtDropOff;

  /// Peak pace (best 3-lap average) and the average from the drop-off
  /// lap on, in ms.
  final double peakPaceMs;
  final double paceSinceMs;

  const TyreDropOff({
    required this.fromLapNumber,
    required this.lapsBeforeDropOff,
    required this.wearPercentAtDropOff,
    required this.peakPaceMs,
    required this.paceSinceMs,
  });

  /// How much slower the laps since the drop-off are than peak pace.
  double get lossMs => paceSinceMs - peakPaceMs;

  Map<String, dynamic> toPromptContext() => {
    'fromLap': fromLapNumber,
    'lapsBeforeDropOff': lapsBeforeDropOff,
    if (wearPercentAtDropOff != null) 'tyresLeftPercentAtDropOff': wearPercentAtDropOff!.round(),
    'secondsSlowerThanPeak': (lossMs / 1000).toStringAsFixed(2),
  };
}

/// Results of one stint (a run on one set of tyres and one fuel load),
/// from its logged laps -- what lets the driver run tyres and fuel to
/// their limit and read off how long each lasts.
///
/// Pit laps are left out of every figure (they include the stop), and
/// so are laps far off the stint's own pace (a spin, an off, traffic,
/// a cold out-lap): they say nothing about the tyres or fuel. A lap is
/// left out when it's more than [outlierSigmas] standard deviations
/// (and at least [outlierFloorMs]) off the median of the laps around
/// it -- judged against its neighbours, not the whole stint, so the
/// gradual slowing of wearing tyres is never mistaken for mistakes.
class StintSummary {
  /// How far off its neighbours a lap must be to be left out.
  static const double outlierSigmas = 3;
  static const double outlierFloorMs = 500;

  /// The spread is never taken as tighter than this, ms (an unusually
  /// metronomic run would otherwise make every small slip an outlier).
  static const double minSigmaMs = 100;

  /// Laps either side of a lap that it's judged against.
  static const int neighbourLaps = 2;

  /// The tyres have gone off once the pace is this many standard
  /// deviations (and at least [dropOffFloorMs]) slower than peak pace,
  /// and stays there.
  static const double dropOffSigmas = 2.5;
  static const double dropOffFloorMs = 400;

  /// Counted laps needed before drop-off can be called.
  static const int dropOffMinLaps = 5;

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

  /// True if the app called this stint's test complete.
  bool get testTargetReached => laps.any((l) => l.testTargetReached);

  /// Laps without a pit stop in them, oldest first.
  late final List<PracticeLapRecord> _noPit = laps.where((l) => !l.isPitLap && l.lapTimeMs > 0).toList();

  late final (List<PracticeLapRecord>, List<PracticeLapRecord>, double?) _filtered = _filter(_noPit);

  /// The laps every figure is worked out from: no pit laps, no outliers.
  List<PracticeLapRecord> get _clean => _filtered.$1;

  /// Laps left out as off the stint's pace (not counting pit laps).
  List<PracticeLapRecord> get excludedLaps => _filtered.$2;

  /// True if [lap] counts towards the stint's figures.
  bool counts(PracticeLapRecord lap) => _clean.contains(lap);

  /// Lap-to-lap consistency of the counted laps: their standard
  /// deviation around the stint's trend, ms. Null under 3 laps.
  double? get consistencyMs => _filtered.$3;

  /// Laps counted towards the figures.
  int get lapCount => _clean.length;

  /// Fastest counted lap, ms.
  int? get bestLapMs => _clean.isEmpty ? null : _clean.map((l) => l.lapTimeMs).reduce(math.min);

  /// Each lap minus the median of it and its [neighbourLaps] either side.
  static List<double> _residuals(List<int> times) => [
    for (var i = 0; i < times.length; i++)
      times[i] -
          _median([
            for (var j = math.max(0, i - neighbourLaps); j <= math.min(times.length - 1, i + neighbourLaps); j++)
              times[j].toDouble(),
          ]),
  ];

  /// Robust standard deviation (1.4826 x median absolute deviation),
  /// so the outliers being looked for don't inflate it.
  static double _robustSigma(List<double> residuals) =>
      math.max(minSigmaMs, 1.4826 * _median([for (final r in residuals) r.abs()]));

  static (List<PracticeLapRecord>, List<PracticeLapRecord>, double?) _filter(List<PracticeLapRecord> laps) {
    if (laps.length < 3) return (laps, const [], null);
    final residuals = _residuals([for (final l in laps) l.lapTimeMs]);
    final limit = math.max(outlierSigmas * _robustSigma(residuals), outlierFloorMs);
    final kept = <PracticeLapRecord>[];
    final dropped = <PracticeLapRecord>[];
    for (var i = 0; i < laps.length; i++) {
      (residuals[i].abs() > limit ? dropped : kept).add(laps[i]);
    }
    if (kept.length < 3) return (kept, dropped, null);
    final keptResiduals = _residuals([for (final l in kept) l.lapTimeMs]);
    final variance = keptResiduals.map((r) => r * r).reduce((a, b) => a + b) / (keptResiduals.length - 1);
    return (kept, dropped, math.sqrt(variance));
  }

  static double _median(List<double> values) {
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  static double _mean(Iterable<num> values) => values.fold<double>(0, (a, b) => a + b) / values.length;

  /// When the tyres went off, if they have: from the counted laps, the
  /// first lap from which the pace is clearly and lastingly slower than
  /// the stint's peak (its best 3-lap average) -- that lap and the next
  /// both over the line, and the median of everything since too, so
  /// one slow lap or a brief dip isn't a drop-off. Fuel burning off
  /// makes the car faster through a stint, so any sustained slowing is
  /// the tyres. Null until [dropOffMinLaps] laps are counted, and while
  /// the pace holds.
  late final TyreDropOff? tyreDropOff = _findDropOff();

  TyreDropOff? _findDropOff() {
    final clean = _clean;
    if (clean.length < dropOffMinLaps) return null;
    final times = [for (final l in clean) l.lapTimeMs.toDouble()];

    var peakStart = 0;
    var peak = double.infinity;
    for (var i = 0; i + 3 <= times.length; i++) {
      final avg = _mean(times.sublist(i, i + 3));
      if (avg < peak) {
        peak = avg;
        peakStart = i;
      }
    }
    final line = peak + math.max(dropOffSigmas * (consistencyMs ?? minSigmaMs), dropOffFloorMs);

    for (var i = peakStart + 1; i + 1 < times.length; i++) {
      if (times[i] <= line || times[i + 1] <= line) continue;
      final since = times.sublist(i);
      if (_median(since) <= line) continue;
      final lap = clean[i];
      final index = laps.indexOf(lap);
      return TyreDropOff(
        fromLapNumber: lap.lapNumber,
        lapsBeforeDropOff: i,
        wearPercentAtDropOff: index > 0 ? laps[index - 1].tireWearPercent : null,
        peakPaceMs: peak,
        paceSinceMs: _mean(since),
      );
    }
    return null;
  }

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

  /// Lap-time drop-off: average of the last 3 counted laps minus the
  /// first 3 (milliseconds; positive = slowing). Needs at least 4 laps.
  double? get dropOffMs {
    final clean = _clean;
    if (clean.length < 4) return null;
    final n = clean.length >= 6 ? 3 : clean.length ~/ 2;
    double avg(Iterable<PracticeLapRecord> l) => l.map((x) => x.lapTimeMs).reduce((a, b) => a + b) / n;
    return avg(clean.sublist(clean.length - n)) - avg(clean.take(n));
  }

  /// The stint for Boxington: what's counted, how consistent, and
  /// whether the tyres have gone off.
  Map<String, dynamic> toPromptContext() => {
    'stint': stintNumber,
    'tyre': tyreCompound,
    'lapsCounted': lapCount,
    'lapsLeftOutAsOffPace': excludedLaps.length,
    if (consistencyMs != null) 'consistencySeconds': (consistencyMs! / 1000).toStringAsFixed(2),
    if (latestTyreWearPercent != null) 'tyresLeftPercent': latestTyreWearPercent!.round(),
    'tyresDroppedOff': tyreDropOff?.toPromptContext(),
  };
}

/// Boxington's drop-off call (Practice Mode): once per stint, the first
/// time the stint's tyres are found to have gone off.
class TyreDropOffCaller {
  int? _calledStint;

  void reset() => _calledStint = null;

  String? check(StintSummary? stint) {
    final dropOff = stint?.tyreDropOff;
    if (stint == null || dropOff == null || _calledStint == stint.stintNumber) return null;
    _calledStint = stint.stintNumber;
    final wear = dropOff.wearPercentAtDropOff;
    return 'TYRE DROP-OFF: the ${stint.tyreCompound} tyres have gone off from lap ${dropOff.fromLapNumber}, '
        'after ${dropOff.lapsBeforeDropOff} laps at peak pace'
        '${wear == null ? '' : ' (${wear.round()}% tyre left)'}: '
        '${(dropOff.lossMs / 1000).toStringAsFixed(1)}s a lap slower since. '
        'Tell the driver, in one short transmission, and that it is logged.';
  }
}
