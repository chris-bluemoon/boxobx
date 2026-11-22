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
/// (and at least [outlierFloorMs], or [outlierFloorShareOfLap] of a
/// typical lap if more) slower than the laps around it -- judged
/// against its neighbours, not the whole stint, so the slowing of
/// wearing tyres is never mistaken for mistakes (see [_offNeighbours]).
class StintSummary {
  /// How far off its neighbours a lap must be to be left out.
  static const double outlierSigmas = 3;
  static const double outlierFloorMs = 500;

  /// ...and at least this share of a typical lap: on a long lap, normal
  /// lap-to-lap spread is bigger (19 Nov, Sainte-Croix C at 3:40: a lap
  /// 1.1 s off a steep fuel-burn trend was being called off pace).
  static const double outlierFloorShareOfLap = 0.0075;

  /// The spread is never taken as tighter than this, ms (an unusually
  /// metronomic run would otherwise make every small slip an outlier).
  static const double minSigmaMs = 100;

  /// Laps either side of a lap that it's judged against.
  static const int neighbourLaps = 2;

  /// A slow lap the pace never comes back from -- no later lap of the
  /// stint clearly quicker -- is the tyres going, not a mistake, when
  /// the gauge shows them this worn (percent left) or it's one of
  /// [fadeRunLaps] or more such laps at the end; unless a spin was
  /// logged on it or it's more than [maxFadeMs] off (an off).
  static const double wornTyresPercent = 60;
  static const int fadeRunLaps = 2;
  static const double maxFadeMs = 8000;

  /// The tyres have gone off once the pace is this many standard
  /// deviations (and at least [dropOffFloorMs]) slower than peak pace,
  /// and stays there.
  static const double dropOffSigmas = 2.5;
  static const double dropOffFloorMs = 400;

  /// Counted laps needed before drop-off can be called -- 3, so a stint
  /// as short as a heavy-fuel tank (4 laps) can show one.
  static const int dropOffMinLaps = 3;

  /// The car gets lighter as the fuel burns, and quicker: about this
  /// share of a lap per percent of the tank (0.037 s a % on a 3:40 lap,
  /// Sainte-Croix C at x4). Used until the round's own laps measure it
  /// ([fuelGainMsPerPercent]).
  static const double fuelGainShareOfLapPerPercent = 0.00017;

  /// What one percent of fuel is worth a lap, ms: measured from the
  /// round's stints -- how much quicker each got per percent burned (the
  /// median, lap time against fuel) -- held between half and three times
  /// the [fuelGainShareOfLapPerPercent] figure (tyre wear slows a stint
  /// too, so a measured figure runs low); that figure with no stint to
  /// go on.
  final double fuelGainMsPerPercent;

  final int stintNumber;
  final bool isRace;

  /// Every lap in the stint, oldest first (including pit laps).
  final List<PracticeLapRecord> laps;

  StintSummary._(this.stintNumber, this.isRace, this.laps, this.fuelGainMsPerPercent);

  /// Groups laps into stints, newest stint first. Laps logged before
  /// stints existed (stintNumber 0) form one group of their own.
  static List<StintSummary> fromLaps(List<PracticeLapRecord> laps) {
    final byStint = <int, List<PracticeLapRecord>>{};
    for (final lap in laps) {
      byStint.putIfAbsent(lap.stintNumber, () => []).add(lap);
    }
    final numbers = byStint.keys.toList()..sort((a, b) => b.compareTo(a));
    final gain = _fuelGain(byStint.values);
    return [for (final n in numbers) StintSummary._(n, byStint[n]!.any((l) => l.isRaceLap), byStint[n]!, gain)];
  }

  static double _fuelGain(Iterable<List<PracticeLapRecord>> stints) {
    final allTimes = [
      for (final stint in stints)
        for (final l in stint)
          if (!l.isPitLap && l.lapTimeMs > 0) l.lapTimeMs.toDouble(),
    ];
    if (allTimes.isEmpty) return 0;
    final assumed = fuelGainShareOfLapPerPercent * _median(allTimes);
    final slopes = <double>[];
    for (final stint in stints) {
      // Not the first lap: out of the pits on cold tyres, it's slow for
      // that, not the fuel -- and on a short heavy-fuel stint it would
      // make the fuel look worth far more than it is.
      final laps = [
        for (final l in stint.skip(1))
          if (!l.isPitLap && l.lapTimeMs > 0 && !l.isRaceLap) l,
      ];
      if (laps.length < 3 || laps.map((l) => l.fuelMap ?? 1).toSet().length > 1) continue;
      // Theil-Sen: the median of every pair's ms per percent burned.
      final pairs = [
        for (var i = 0; i < laps.length; i++)
          for (var j = i + 1; j < laps.length; j++)
            if (laps[i].fuelPercentAtLapStart - laps[j].fuelPercentAtLapStart > 1)
              (laps[i].lapTimeMs - laps[j].lapTimeMs) / (laps[i].fuelPercentAtLapStart - laps[j].fuelPercentAtLapStart),
      ];
      if (pairs.isNotEmpty) slopes.add(_median(pairs));
    }
    if (slopes.isEmpty) return assumed;
    return _median(slopes).clamp(assumed / 2, assumed * 3);
  }

  /// [lap]'s time as if on the stint's starting fuel: what the lighter
  /// car gained added back.
  double fuelCorrectedMs(PracticeLapRecord lap) =>
      lap.lapTimeMs + fuelGainMsPerPercent * (startFuelPercent - lap.fuelPercentAtLapStart).clamp(0, 100);

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

  /// Laps driven, pit laps aside -- off-pace ones included (what a
  /// fixed-length test counts: the driver did the lap).
  int get lapsDriven => _noPit.length;

  /// Fastest counted lap, ms.
  int? get bestLapMs => _clean.isEmpty ? null : _clean.map((l) => l.lapTimeMs).reduce(math.min);

  /// Laps either side used for a lap's local trend.
  static const int trendLaps = 3;

  /// How far each lap is off the laps around it: the smaller of its
  /// distance from their median (which follows a sudden step, like a
  /// tyre cliff, but lags a steady fade at the ends of the stint) and
  /// from their local trend (which follows a fade right to the latest
  /// lap, but not a step). A lap is only off-pace if it's off both --
  /// a spin is; the latest lap of a fading stint, or the first after a
  /// cliff, isn't.
  static List<double> _residuals(List<int> times) => [
    for (var i = 0; i < times.length; i++) _offNeighbours(times, i),
  ];

  static double _offNeighbours(List<int> times, int i) {
    final fromMedian =
        times[i] -
        _median([
          for (var j = math.max(0, i - neighbourLaps); j <= math.min(times.length - 1, i + neighbourLaps); j++)
            times[j].toDouble(),
        ]);
    final trend = _trendAt(times, i);
    if (trend == null) return fromMedian;
    final fromTrend = times[i] - trend;
    return fromTrend.abs() < fromMedian.abs() ? fromTrend : fromMedian;
  }

  /// Lap [i]'s time as predicted by a Theil-Sen line (median of the
  /// pairwise slopes, so one bad lap among them doesn't bend it) through
  /// the laps within [trendLaps] of it, not counting lap [i] itself.
  /// Null with fewer than 3 such laps.
  static double? _trendAt(List<int> times, int i) {
    final around = [
      for (var j = math.max(0, i - trendLaps); j <= math.min(times.length - 1, i + trendLaps); j++)
        if (j != i) j,
    ];
    if (around.length < 3) return null;
    final slope = _median([
      for (var a = 0; a < around.length; a++)
        for (var b = a + 1; b < around.length; b++)
          (times[around[b]] - times[around[a]]) / (around[b] - around[a]),
    ]);
    return _median([for (final j in around) times[j] + slope * (i - j)]);
  }

  /// Robust standard deviation (1.4826 x median absolute deviation),
  /// so the outliers being looked for don't inflate it.
  static double _robustSigma(List<double> residuals) =>
      math.max(minSigmaMs, 1.4826 * _median([for (final r in residuals) r.abs()]));

  static (List<PracticeLapRecord>, List<PracticeLapRecord>, double?) _filter(List<PracticeLapRecord> laps) {
    if (laps.length < 3) return (laps, const [], null);
    final residuals = _residuals([for (final l in laps) l.lapTimeMs]);
    final typical = _median([for (final l in laps) l.lapTimeMs.toDouble()]);
    final limit = math.max(outlierSigmas * _robustSigma(residuals), math.max(outlierFloorMs, outlierFloorShareOfLap * typical));
    // Only SLOW laps are off pace: a lap quicker than those around it is
    // the driver's real pace, not a mistake (19 Nov: the fastest of a
    // 3-lap fuel map test was left out, so the test never completed).
    final off = [for (var i = 0; i < laps.length; i++) residuals[i] > limit];
    final steady = [
      for (var i = 0; i < laps.length; i++)
        if (!off[i]) laps[i],
    ];

    // Slow laps at the end of a stint the pace never recovers from: the
    // tyres going, not mistakes (16 Nov: the last lap on 25% Inters was
    // being left out as off pace).
    bool recovers(int i) => [for (var j = i + 1; j < laps.length; j++) laps[j].lapTimeMs].any((t) => t < laps[i].lapTimeMs - limit);
    final fade = [
      for (var i = 0; i < laps.length; i++)
        off[i] && residuals[i] > 0 && residuals[i] <= maxFadeMs && laps[i].spinCount == 0 && !recovers(i),
    ];
    var run = 0;
    final kept = <PracticeLapRecord>[];
    final dropped = <PracticeLapRecord>[];
    for (var i = laps.length - 1; i >= 0; i--) {
      run = fade[i] ? run + 1 : 0;
      final worn = (laps[i].tireWearPercent ?? 100) <= wornTyresPercent;
      if (!off[i] || (fade[i] && (worn || run >= fadeRunLaps || (i + 1 < laps.length && fade[i + 1])))) {
        kept.insert(0, laps[i]);
      } else {
        dropped.insert(0, laps[i]);
      }
    }

    // Consistency from the steady laps only: the faded ones would widen
    // it (and with it the drop-off line they show).
    if (steady.length < 3) return (kept, dropped, null);
    final steadyResiduals = _residuals([for (final l in steady) l.lapTimeMs]);
    final variance = steadyResiduals.map((r) => r * r).reduce((a, b) => a + b) / (steadyResiduals.length - 1);
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
  /// the stint's peak (its best 3-lap average; 2 laps under 6, 1 under
  /// 4) -- that lap and the next both over the line, and the median of
  /// everything since too, so one slow lap or a brief dip isn't a
  /// drop-off. The times are taken fuel-corrected ([fuelCorrectedMs]):
  /// the car getting lighter would otherwise hide the tyres going. Null
  /// until [dropOffMinLaps] laps are counted, and while the pace holds.
  late final TyreDropOff? tyreDropOff = _findDropOff();

  TyreDropOff? _findDropOff() {
    final clean = _clean;
    if (clean.length < dropOffMinLaps) return null;
    final times = [for (final l in clean) fuelCorrectedMs(l)];
    final window = times.length >= 6 ? 3 : (times.length >= 4 ? 2 : 1);

    var peakStart = 0;
    var peak = double.infinity;
    for (var i = 0; i + window <= times.length; i++) {
      final avg = _mean(times.sublist(i, i + window));
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

  /// The weather the stint was tested in: "DRY" or a rain preset
  /// ("R05"), the most common across its laps.
  String get weatherLevel {
    final counts = <String, int>{};
    for (final lap in laps) {
      counts[lap.weatherLevel] = (counts[lap.weatherLevel] ?? 0) + 1;
    }
    return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  /// The stint's typical lap: the median of its counted laps (ms), or
  /// null if none.
  double? get typicalLapMs => _clean.isEmpty ? null : _median([for (final l in _clean) l.lapTimeMs.toDouble()]);

  /// GT7's short code for the compound, as on the in-game HUD.
  static String compoundCode(String compound) => switch (compound) {
    'Racing Soft' => 'RS',
    'Racing Medium' => 'RM',
    'Racing Hard' => 'RH',
    'Intermediate' => 'IM',
    'Heavy Wet' => 'W',
    _ => compound,
  };

  /// e.g. "Round 5 Practice - Stint 1 - Fuel 100%, Tyre RS".
  String label(String? roundName) {
    if (stintNumber == 0) return '${roundName ?? 'Practice'} - Earlier laps (before stints)';
    final round = roundName ?? 'Practice';
    final test = testNumber == null ? '' : ' (Stint Test $testNumber)';
    return '$round ${isRace ? 'Race' : 'Practice'} - Stint $stintNumber$test - '
        'Fuel ${startFuelPercent.toStringAsFixed(0)}%, Tyre ${compoundCode(tyreCompound)}'
        '${weatherLevel == 'DRY' ? '' : ', Weather $weatherLevel'}'
        '${waterLabel == null ? '' : ', ${waterLabel![0].toUpperCase()}${waterLabel!.substring(1)}'}';
  }

  double? get averageLapMs {
    final clean = _clean;
    if (clean.isEmpty) return null;
    return clean.map((l) => l.lapTimeMs).reduce((a, b) => a + b) / clean.length;
  }

  /// Average share of full-throttle time spent spinning a wheel, and of
  /// braking time locking one, over the counted laps that have it (see
  /// GripTracker) -- percent; null if none do. Higher = less grip: on a
  /// wet track these climb with the water.
  double? get wheelspinPercent => _meanOf((l) => l.wheelspinPercent);
  double? get lockupPercent => _meanOf((l) => l.lockupPercent);

  /// Surface water (GT7's gauge) on the stint's first and last laps that
  /// have a reading, percent -- e.g. 48 -> 21 for a drying run; null if
  /// never read.
  (double, double)? get waterRange {
    final read = [for (final l in laps) ?l.waterPercent];
    return read.isEmpty ? null : (read.first, read.last);
  }

  /// "water 48%" or "water 48-21%".
  String? get waterLabel {
    final range = waterRange;
    if (range == null) return null;
    final (from, to) = range;
    return (from - to).abs() < 3 ? 'water ${from.round()}%' : 'water ${from.round()}-${to.round()}%';
  }

  double? _meanOf(double? Function(PracticeLapRecord) field) {
    final values = [for (final l in _clean) ?field(l)];
    return values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length;
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
    'weather': weatherLevel,
    if (waterLabel != null) 'surfaceWater': waterLabel,
    'lapsCounted': lapCount,
    'lapsLeftOutAsOffPace': excludedLaps.length,
    if (consistencyMs != null) 'consistencySeconds': (consistencyMs! / 1000).toStringAsFixed(2),
    if (latestTyreWearPercent != null) 'tyresLeftPercent': latestTyreWearPercent!.round(),
    'tyresDroppedOff': tyreDropOff?.toPromptContext(),
    if (wheelspinPercent != null) 'wheelspinPercentOfFullThrottle': wheelspinPercent!.toStringAsFixed(1),
    if (lockupPercent != null) 'lockupPercentOfBraking': lockupPercent!.toStringAsFixed(1),
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
