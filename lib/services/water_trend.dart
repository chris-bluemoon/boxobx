import 'dart:collection';

/// Which way the surface water is going, from the relay's readings of
/// GT7's water gauge: a straight line through the last [windowSeconds],
/// so Boxington can see a crossover coming rather than call it the lap
/// the track has already turned. (Measured on the Nurburgring: after the
/// rain stopped, the gauge fell about 3% a minute.)
class WaterTrend {
  /// Readings used for the line...
  static const int windowSeconds = 90;

  /// ...which needs at least this many, spanning at least this long.
  static const int minReadings = 6;
  static const int minSpanSeconds = 30;

  /// Slower than this either way is steady (the gauge reads to ~1%).
  static const double steadyPercentPerMinute = 0.5;

  final _readings = Queue<(DateTime, double)>();

  void add(double percent, DateTime at) {
    _readings.add((at, percent));
    while (_readings.isNotEmpty && at.difference(_readings.first.$1).inSeconds > windowSeconds) {
      _readings.removeFirst();
    }
  }

  void reset() => _readings.clear();

  /// Water change per minute, percentage points (negative = drying), or
  /// null without enough readings.
  double? get percentPerMinute {
    if (_readings.length < minReadings) return null;
    final t0 = _readings.first.$1;
    final xs = [for (final (t, _) in _readings) t.difference(t0).inMilliseconds / 60000];
    if (xs.last * 60 < minSpanSeconds) return null;
    final ys = [for (final (_, w) in _readings) w];
    final n = xs.length;
    final mx = xs.reduce((a, b) => a + b) / n, my = ys.reduce((a, b) => a + b) / n;
    var sxy = 0.0, sxx = 0.0;
    for (var i = 0; i < n; i++) {
      sxy += (xs[i] - mx) * (ys[i] - my);
      sxx += (xs[i] - mx) * (xs[i] - mx);
    }
    return sxx == 0 ? null : sxy / sxx;
  }

  /// Seconds until the water reaches [level] at the current rate, if it's
  /// heading that way; null if not (or steady, or unknown).
  double? secondsTo(double level, double water) {
    final rate = percentPerMinute;
    if (rate == null || rate.abs() < steadyPercentPerMinute) return null;
    final gap = level - water;
    if (gap == 0) return 0;
    if (gap.sign != rate.sign) return null;
    return gap / rate * 60;
  }
}
