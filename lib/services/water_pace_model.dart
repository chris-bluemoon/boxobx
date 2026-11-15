import '../models/practice_lap_record.dart';
import '../models/weather_forecast.dart';
import 'stint_summary.dart';
import 'wet_pace_table.dart';

/// One tyre's lap time against surface water: a straight line through
/// its practice laps (lap ms = intercept + slope x water %), over the
/// water it was run in.
class TyreWaterFit {
  final WeatherTyre tyre;
  final double interceptMs;
  final double slopeMsPerPercent;
  final double minWater;
  final double maxWater;
  final int laps;

  const TyreWaterFit(this.tyre, this.interceptMs, this.slopeMsPerPercent, this.minWater, this.maxWater, this.laps);

  double predictMs(double water) => interceptMs + slopeMsPerPercent * water;

  /// True if [water] is in (or within [WaterPaceModel.reachPercent] of)
  /// the water this tyre was run in.
  bool covers(double water) =>
      water >= minWater - WaterPaceModel.reachPercent && water <= maxWater + WaterPaceModel.reachPercent;

  /// "Intermediate 1:44.2 at 50%, +0.08s per 1% water (8 laps, 31-62%)".
  String describe() {
    final mid = (minWater + maxWater) / 2;
    final range = (maxWater - minWater) < 1 ? '${minWater.round()}%' : '${minWater.round()}-${maxWater.round()}%';
    return '${tyre.label} ${WaterPaceModel.formatMs(predictMs(mid))} at ${mid.round()}%, '
        '${slopeMsPerPercent >= 0 ? '+' : ''}${(slopeMsPerPercent / 1000).toStringAsFixed(2)}s per 1% water '
        '($laps laps, $range)';
  }
}

/// Each tyre's pace against the surface water GT7 shows (read by the
/// relay), learnt from every lap with a reading -- practice and races, no
/// dedicated tests -- so each wet session sharpens the numbers. Where two tyres' lines cross is the measured crossover --
/// the water level below which the drier tyre is faster. Until a
/// crossover is measured, GT7's own gauge lines stand in: below 33%
/// slicks, 33-66% intermediates, above 66% wets (community testing).
class WaterPaceModel {
  /// GT7's lines on the gauge.
  static const double intersFromPercent = 100 / 3;
  static const double wetsFromPercent = 200 / 3;

  /// A tyre needs this many laps with a reading to be fitted...
  static const int minLaps = 3;

  /// ...and this spread of water for a slope (less, and it's taken as
  /// flat: one pace at that water).
  static const double minSpreadPercent = 8;

  /// How far beyond its tested water a tyre's line is trusted.
  static const double reachPercent = 10;

  final Map<WeatherTyre, TyreWaterFit> fits;
  const WaterPaceModel(this.fits);

  factory WaterPaceModel.fromLaps(List<PracticeLapRecord> laps) {
    final points = <WeatherTyre, List<(double, int)>>{};
    for (final stint in StintSummary.fromLaps(laps)) {
      if (stint.stintNumber == 0) continue;
      for (final lap in stint.laps) {
        final water = lap.waterPercent;
        if (water == null || !stint.counts(lap)) continue;
        // A race stint's first lap is the start or the out-lap.
        if (stint.isRace && identical(lap, stint.laps.first)) continue;
        (points[WetPaceTable.tyreOf(lap.tireCompound)] ??= []).add((water, lap.lapTimeMs));
      }
    }
    return WaterPaceModel({
      for (final MapEntry(key: tyre, value: p) in points.entries)
        if (p.length >= minLaps) tyre: _fit(tyre, p),
    });
  }

  static TyreWaterFit _fit(WeatherTyre tyre, List<(double, int)> points) {
    final n = points.length;
    final waters = [for (final (w, _) in points) w];
    final minW = waters.reduce((a, b) => a < b ? a : b), maxW = waters.reduce((a, b) => a > b ? a : b);
    final meanW = waters.reduce((a, b) => a + b) / n;
    final meanT = points.map((p) => p.$2).reduce((a, b) => a + b) / n;
    var slope = 0.0;
    if (maxW - minW >= minSpreadPercent) {
      var sxy = 0.0, sxx = 0.0;
      for (final (w, t) in points) {
        sxy += (w - meanW) * (t - meanT);
        sxx += (w - meanW) * (w - meanW);
      }
      slope = sxx == 0 ? 0 : sxy / sxx;
    }
    return TyreWaterFit(tyre, meanT - slope * meanW, slope, minW, maxW, n);
  }

  bool get isEmpty => fits.isEmpty;

  /// Lap time gained a lap by running [to] instead of [from] at [water]
  /// (ms, negative if slower), or null if either wasn't run near it.
  double? gainMs(WeatherTyre from, WeatherTyre to, double water) {
    final a = fits[from], b = fits[to];
    if (a == null || b == null || !a.covers(water) || !b.covers(water)) return null;
    return a.predictMs(water) - b.predictMs(water);
  }

  /// The measured water level where [drier] and [wetter] are equally
  /// quick (below it [drier] is faster), or null if their lines don't
  /// cross within the water they were run in.
  double? measuredCrossover(WeatherTyre drier, WeatherTyre wetter) {
    final a = fits[drier], b = fits[wetter];
    if (a == null || b == null) return null;
    final dSlope = a.slopeMsPerPercent - b.slopeMsPerPercent;
    if (dSlope.abs() < 1e-9) return null;
    final w = (b.interceptMs - a.interceptMs) / dSlope;
    final low = (a.minWater > b.minWater ? a.minWater : b.minWater) - reachPercent;
    final high = (a.maxWater < b.maxWater ? a.maxWater : b.maxWater) + reachPercent;
    if (w < low || w > high || w < 0 || w > 100) return null;
    // Below the crossing the drier tyre has to be the quicker one.
    if (a.predictMs(w - 1) > b.predictMs(w - 1)) return null;
    return w;
  }

  /// Where [drier] gives way to the next wetter tyre: measured if it
  /// can be, else GT7's gauge line.
  (double, bool) crossover(WeatherTyre drier) {
    final wetter = WeatherTyre.values[drier.index + 1];
    final measured = measuredCrossover(drier, wetter);
    if (measured != null) return (measured, true);
    return (drier == WeatherTyre.slicks ? intersFromPercent : wetsFromPercent, false);
  }

  /// The tyre for [water], by the crossovers.
  WeatherTyre tyreFor(double water) {
    if (water < crossover(WeatherTyre.slicks).$1) return WeatherTyre.slicks;
    if (water < crossover(WeatherTyre.inters).$1) return WeatherTyre.inters;
    return WeatherTyre.wets;
  }

  /// For Boxington: each tyre's line and the crossovers.
  Map<String, dynamic> toPromptContext() {
    String cross(WeatherTyre drier) {
      final (w, measured) = crossover(drier);
      return '${WeatherTyre.values[drier.index + 1].label} from ${w.round()}% water '
          '(${measured ? 'measured in testing' : "GT7's gauge line, not measured yet"})';
    }

    return {
      'tyrePaceByWater': [for (final f in fits.values) f.describe()],
      'crossovers': [cross(WeatherTyre.slicks), cross(WeatherTyre.inters)],
    };
  }

  static String formatMs(double ms) {
    final minutes = ms ~/ 60000;
    return '$minutes:${((ms % 60000) / 1000).toStringAsFixed(1).padLeft(4, '0')}';
  }
}
