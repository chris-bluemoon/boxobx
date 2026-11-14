import '../models/corner.dart';
import '../models/reference_lap.dart';

/// Finds a layout's corners from a lap's speed trace: each place the
/// speed dips to a low point and picks up again. A low point counts if
/// it's the slowest within [_windowMeters] either side, at least
/// [_minDropKmh] slower than the fastest point in the [_lookMeters]
/// before it, and the car is at least [_minRecoveryKmh] faster again
/// within [_lookMeters] after it -- so a flat-out kink or a lift isn't a
/// corner, and a double-apex corner with one low point is one corner.
class CornerDetector {
  static const double _windowMeters = 60;
  static const double _lookMeters = 250;
  static const double _minDropKmh = 12;
  static const double _minRecoveryKmh = 8;
  static const double _smoothMeters = 10;

  static List<Corner> detect(ReferenceLap lap) {
    if (!lap.hasSpeedAndBrake) return const [];
    final d = lap.distances;
    final n = lap.length;

    // Speeds averaged over a few metres, so one noisy sample isn't a
    // corner.
    final speed = <double>[];
    for (var i = 0; i < n; i++) {
      var sum = 0.0, count = 0;
      for (var j = i; j >= 0 && d[i] - d[j] <= _smoothMeters; j--) {
        sum += lap.speedsKmh[j];
        count++;
      }
      for (var j = i + 1; j < n && d[j] - d[i] <= _smoothMeters; j++) {
        sum += lap.speedsKmh[j];
        count++;
      }
      speed.add(sum / count);
    }

    final apexes = <int>[];
    for (var i = 0; i < n; i++) {
      var isLow = true;
      var peakBefore = speed[i], peakAfter = speed[i];
      for (var j = i - 1; j >= 0 && d[i] - d[j] <= _lookMeters; j--) {
        // Strictly slower than everything just before, no slower than
        // anything just after: one apex per flat-bottomed dip.
        if (d[i] - d[j] <= _windowMeters && speed[j] <= speed[i]) isLow = false;
        if (speed[j] > peakBefore) peakBefore = speed[j];
      }
      for (var j = i + 1; j < n && d[j] - d[i] <= _lookMeters; j++) {
        if (d[j] - d[i] <= _windowMeters && speed[j] < speed[i]) isLow = false;
        if (speed[j] > peakAfter) peakAfter = speed[j];
      }
      if (!isLow) continue;
      if (peakBefore - speed[i] < _minDropKmh || peakAfter - speed[i] < _minRecoveryKmh) continue;
      apexes.add(i);
    }

    return [for (final (k, i) in apexes.indexed) Corner(number: k + 1, x: lap.xs[i], z: lap.zs[i])];
  }
}
