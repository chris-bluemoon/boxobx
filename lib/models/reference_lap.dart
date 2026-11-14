import 'dart:math' as math;

import 'sector_map.dart';

/// A lap as a trace of where the car was, when, how fast and how hard on
/// the brakes -- the fastest clean lap at a layout in one car is kept as
/// the reference the live delta and corner report measure against (see
/// SectorCalculator), and the last lap is kept the same way to compare
/// with it. Points are roughly every [spacingMeters] along the lap, plus
/// one wherever the brake goes on or off (so brake points are exact to a
/// frame, not to the spacing); times (ms from the line) are squared up
/// with GT7's official lap time.
class ReferenceLap {
  final int lapTimeMs;
  final List<double> xs, zs;
  final List<int> timesMs;

  /// Speed (km/h) and brake pedal (0-100) at each point. Empty on traces
  /// saved before they were recorded.
  final List<double> speedsKmh;
  final List<int> brakes;

  /// The round it was set in (see SavedBriefingStore) -- the delta only
  /// compares against a reference from the current round.
  final String? round;

  ReferenceLap({
    required this.lapTimeMs,
    required this.xs,
    required this.zs,
    required this.timesMs,
    this.speedsKmh = const [],
    this.brakes = const [],
    this.round,
  });

  static const double spacingMeters = 5;

  /// Brake pedal at or above this (%) counts as braking.
  static const int brakeOnPercent = 10;

  int get length => xs.length;

  bool get hasSpeedAndBrake => speedsKmh.length == length && brakes.length == length && length > 1;

  /// Distance (m) from the line to each point, along the trace.
  late final List<double> distances = () {
    final d = <double>[0];
    for (var i = 1; i < length; i++) {
      d.add(d.last + math.sqrt(math.pow(xs[i] - xs[i - 1], 2) + math.pow(zs[i] - zs[i - 1], 2)));
    }
    return d;
  }();

  /// Builds a trace from a lap's [path], started at [lapStart] on the
  /// packet clock, scaled so it finishes at [officialLapMs].
  static ReferenceLap? fromPath(
    List<PathSample> path,
    double lapStart,
    double lapEnd,
    int officialLapMs, {
    String? round,
  }) {
    final total = lapEnd - lapStart;
    if (path.length < 2 || total <= 0) return null;
    final scale = officialLapMs / (total * 1000);
    final xs = <double>[], zs = <double>[], vs = <double>[];
    final ts = <int>[], bs = <int>[];
    void add(PathSample s) {
      xs.add(s.x);
      zs.add(s.z);
      ts.add(((s.t - lapStart) * 1000 * scale).round().clamp(0, officialLapMs));
      vs.add(s.v);
      bs.add(s.brake.round());
    }

    bool braking(PathSample s) => s.brake >= brakeOnPercent;

    add(path.first);
    var lastAdded = 0;
    for (var i = 1; i < path.length; i++) {
      final s = path[i], last = path[lastAdded];
      final far = math.sqrt(math.pow(s.x - last.x, 2) + math.pow(s.z - last.z, 2)) >= spacingMeters;
      if (far || braking(s) != braking(path[i - 1])) {
        add(s);
        lastAdded = i;
      }
    }
    // End on the lap's last sample, so the final metres to the line are
    // covered too.
    if (lastAdded != path.length - 1) add(path.last);
    return ReferenceLap(lapTimeMs: officialLapMs, xs: xs, zs: zs, timesMs: ts, speedsKmh: vs, brakes: bs, round: round);
  }

  /// Where (x, z) is along the trace, searching forward from [fromIndex]
  /// (laps only go one way, and that stops a crossover -- a bridge, a
  /// figure of eight -- matching the wrong part of the lap). Returns the
  /// segment index, the reference time (ms) and distance (m) there,
  /// interpolated; null if the car is nowhere near the trace (off track,
  /// in the pits).
  ({int index, double timeMs, double distance})? locate(double x, double z, int fromIndex) {
    if (length < 2) return null;
    const back = 4, ahead = 80, maxOffTraceMeters = 50.0;
    final first = math.max(0, fromIndex - back);
    final last = math.min(length - 2, fromIndex + ahead);
    var bestIndex = -1;
    var bestDistance = double.infinity;
    var bestFraction = 0.0;
    for (var i = first; i <= last; i++) {
      final ax = xs[i], az = zs[i];
      final dx = xs[i + 1] - ax, dz = zs[i + 1] - az;
      final len2 = dx * dx + dz * dz;
      final f = len2 == 0 ? 0.0 : (((x - ax) * dx + (z - az) * dz) / len2).clamp(0.0, 1.0);
      final px = ax + dx * f, pz = az + dz * f;
      final d = math.sqrt(math.pow(x - px, 2) + math.pow(z - pz, 2));
      if (d < bestDistance) {
        bestDistance = d;
        bestIndex = i;
        bestFraction = f;
      }
    }
    if (bestIndex < 0 || bestDistance > maxOffTraceMeters) return null;
    final i = bestIndex;
    return (
      index: i,
      timeMs: timesMs[i] + (timesMs[i + 1] - timesMs[i]) * bestFraction,
      distance: distances[i] + (distances[i + 1] - distances[i]) * bestFraction,
    );
  }

  factory ReferenceLap.fromMap(Map<String, dynamic> m) => ReferenceLap(
    lapTimeMs: (m['lapTimeMs'] as num).toInt(),
    xs: [for (final v in m['xs'] as List) (v as num).toDouble()],
    zs: [for (final v in m['zs'] as List) (v as num).toDouble()],
    timesMs: [for (final v in m['ts'] as List) (v as num).toInt()],
    speedsKmh: [for (final v in (m['vs'] as List?) ?? const []) (v as num).toDouble()],
    brakes: [for (final v in (m['bs'] as List?) ?? const []) (v as num).toInt()],
    round: m['round'] as String?,
  );

  Map<String, dynamic> toMap() => {
    'lapTimeMs': lapTimeMs,
    'xs': [for (final v in xs) double.parse(v.toStringAsFixed(1))],
    'zs': [for (final v in zs) double.parse(v.toStringAsFixed(1))],
    'ts': timesMs,
    'vs': [for (final v in speedsKmh) double.parse(v.toStringAsFixed(1))],
    'bs': brakes,
    if (round != null) 'round': round,
  };
}
