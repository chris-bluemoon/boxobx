import 'dart:math' as math;

import '../models/corner.dart';
import '../models/reference_lap.dart';

/// Braking into one corner on one lap: where it started (distance along
/// the reference lap, so the two laps are comparable), the hardest the
/// pedal went, and how long the zone was.
class CornerBraking {
  final double startDistance;
  final double x, z;
  final int peakPercent;
  final double zoneMeters;

  const CornerBraking({
    required this.startDistance,
    required this.x,
    required this.z,
    required this.peakPercent,
    required this.zoneMeters,
  });
}

/// One lap's way through one corner.
class CornerPass {
  /// Speed (km/h) where braking began (or the fastest point before the
  /// apex, if there was no braking), the slowest point, and
  /// [CornerReport.exitMeters] after it.
  final double entryKmh, minKmh, exitKmh;

  /// Null if the corner was taken without braking (a lift or flat out).
  final CornerBraking? braking;

  const CornerPass({required this.entryKmh, required this.minKmh, required this.exitKmh, this.braking});
}

/// The last lap against the reference through one corner.
class CornerResult {
  final Corner corner;

  /// Time lost (+) or gained (-) over this corner's stretch of the lap
  /// (ms). The stretches run from halfway between corners to halfway, so
  /// they add up to the whole lap's gap.
  final double timeDeltaMs;

  final CornerPass lap, reference;

  /// The stretch of the lap this corner covers (distance along the
  /// reference lap, m) -- what the map zooms to.
  final double fromDistance, toDistance;

  /// Where the apex is along the reference lap (m).
  final double apexDistance;

  /// The part of the lap worth looking at on the map: from a little
  /// before the earlier brake point to a little past the exit.
  (double, double) get viewRange {
    final brakes = [lap.braking?.startDistance, reference.braking?.startDistance].whereType<double>();
    final firstBrake = brakes.isEmpty ? apexDistance - 120 : brakes.reduce(math.min);
    return (
      math.max(fromDistance, math.min(firstBrake, apexDistance - 60) - 50),
      math.min(toDistance, apexDistance + CornerReport.exitMeters + 50),
    );
  }

  const CornerResult({
    required this.corner,
    required this.timeDeltaMs,
    required this.lap,
    required this.reference,
    required this.fromDistance,
    required this.toDistance,
    required this.apexDistance,
  });

  /// Metres later (+) or earlier (-) on the brakes than the reference;
  /// null unless both braked.
  double? get brakeDeltaMeters {
    final a = lap.braking, b = reference.braking;
    return a == null || b == null ? null : a.startDistance - b.startDistance;
  }

  double get minDeltaKmh => lap.minKmh - reference.minKmh;
  double get entryDeltaKmh => lap.entryKmh - reference.entryKmh;
  double get exitDeltaKmh => lap.exitKmh - reference.exitKmh;

  /// One line for Boxington, e.g. "corner 4: 0.21 s lost, braked 8 m
  /// earlier, minimum speed 6 km/h lower, exit 3 km/h lower".
  String describe() {
    final parts = <String>[
      'corner ${corner.number}: ${(timeDeltaMs.abs() / 1000).toStringAsFixed(2)} s ${timeDeltaMs >= 0 ? 'lost' : 'gained'}',
    ];
    final brake = brakeDeltaMeters;
    if (brake != null && brake.abs() >= 3) {
      parts.add('braked ${brake.abs().round()} m ${brake < 0 ? 'earlier' : 'later'}');
    } else if (lap.braking == null && reference.braking != null) {
      parts.add("didn't brake (the reference did)");
    } else if (lap.braking != null && reference.braking == null) {
      parts.add('braked where the reference lap did not');
    }
    String speed(String name, double delta) => '$name ${delta.abs().round()} km/h ${delta < 0 ? 'lower' : 'higher'}';
    if (minDeltaKmh.abs() >= 2) parts.add(speed('minimum speed', minDeltaKmh));
    if (exitDeltaKmh.abs() >= 2) parts.add(speed('exit speed', exitDeltaKmh));
    return parts.join(', ');
  }
}

/// The last lap against the reference lap, corner by corner -- entry,
/// minimum and exit speed, braking, and time lost or gained in each.
class CornerReport {
  final ReferenceLap lap, reference;
  final List<CornerResult> corners;
  final DateTime recordedAt;

  CornerReport._(this.lap, this.reference, this.corners, this.recordedAt);

  /// Exit speed is read this far (m) past the slowest point.
  static const double exitMeters = 80;

  int get lapDeltaMs => lap.lapTimeMs - reference.lapTimeMs;

  /// The corner with the most time lost, if any was lost.
  CornerResult? get biggestLoss {
    if (corners.isEmpty) return null;
    final worst = corners.reduce((a, b) => b.timeDeltaMs > a.timeDeltaMs ? b : a);
    return worst.timeDeltaMs > 0 ? worst : null;
  }

  /// Compares [lap] with [reference] at [corners] (in lap order). Null if
  /// either trace lacks speed/brake data or no corner can be placed.
  static CornerReport? compare(ReferenceLap lap, ReferenceLap reference, List<Corner> corners, {DateTime? at}) {
    if (!lap.hasSpeedAndBrake || !reference.hasSpeedAndBrake || corners.isEmpty) return null;
    final refD = reference.distances;
    final lapEnd = refD.last;

    // Each lap point's position along the reference lap.
    final lapOnRef = <double>[];
    var index = 0;
    for (var j = 0; j < lap.length; j++) {
      final at = reference.locate(lap.xs[j], lap.zs[j], index);
      if (at != null) index = at.index;
      final d = at?.distance ?? (lapOnRef.isEmpty ? 0.0 : lapOnRef.last);
      lapOnRef.add(lapOnRef.isEmpty ? d : math.max(d, lapOnRef.last));
    }

    // Apexes placed on the reference, in order.
    final placed = <(Corner, double)>[];
    var from = 0;
    for (final corner in corners) {
      var best = -1;
      var bestDistance = double.infinity;
      for (var i = from; i < reference.length; i++) {
        final dd = math.sqrt(math.pow(reference.xs[i] - corner.x, 2) + math.pow(reference.zs[i] - corner.z, 2));
        if (dd < bestDistance) {
          bestDistance = dd;
          best = i;
        }
      }
      if (best < 0 || bestDistance > 40) continue;
      placed.add((corner, refD[best]));
      from = best;
    }
    if (placed.isEmpty) return null;

    double refTimeAt(double d) => _interpolate(refD, reference.timesMs.map((t) => t.toDouble()).toList(), d);
    double lapTimeAt(double d) => _interpolate(lapOnRef, lap.timesMs.map((t) => t.toDouble()).toList(), d);
    double deltaAt(double d) {
      if (d <= 0) return 0;
      if (d >= lapEnd) return (lap.lapTimeMs - reference.lapTimeMs).toDouble();
      return lapTimeAt(d) - refTimeAt(d);
    }

    final results = <CornerResult>[];
    for (var k = 0; k < placed.length; k++) {
      final (corner, apex) = placed[k];
      final start = k == 0 ? 0.0 : (placed[k - 1].$2 + apex) / 2;
      final end = k == placed.length - 1 ? lapEnd : (apex + placed[k + 1].$2) / 2;
      final previousApex = k == 0 ? 0.0 : placed[k - 1].$2;
      final nextApex = k == placed.length - 1 ? lapEnd : placed[k + 1].$2;
      results.add(
        CornerResult(
          corner: corner,
          timeDeltaMs: deltaAt(end) - deltaAt(start),
          lap: _pass(lap, lapOnRef, start, end, previousApex, nextApex),
          reference: _pass(reference, refD, start, end, previousApex, nextApex),
          fromDistance: start,
          toDistance: end,
          apexDistance: apex,
        ),
      );
    }
    return CornerReport._(lap, reference, results, at ?? DateTime.now());
  }

  /// How a trace went through the stretch [start]-[end] (distances along
  /// the reference, [onRef] per trace point).
  static CornerPass _pass(
    ReferenceLap trace,
    List<double> onRef,
    double start,
    double end,
    double previousApex,
    double nextApex,
  ) {
    final inStretch = [
      for (var i = 0; i < trace.length; i++)
        if (onRef[i] >= start && onRef[i] <= end) i,
    ];
    if (inStretch.isEmpty) return const CornerPass(entryKmh: 0, minKmh: 0, exitKmh: 0);
    final minIndex = inStretch.reduce((a, b) => trace.speedsKmh[b] < trace.speedsKmh[a] ? b : a);
    final minKmh = trace.speedsKmh[minIndex];

    // Braking: the run of brake-on points nearest before the slowest
    // point, after the previous corner's apex.
    bool on(int i) => trace.brakes[i] >= ReferenceLap.brakeOnPercent;
    var zoneEnd = -1;
    for (var i = minIndex; i >= 0 && onRef[i] > previousApex; i--) {
      if (on(i)) {
        zoneEnd = i;
        break;
      }
    }
    CornerBraking? braking;
    var entryKmh = trace.speedsKmh[minIndex];
    if (zoneEnd >= 0) {
      var zoneStart = zoneEnd;
      while (zoneStart > 0 && on(zoneStart - 1) && onRef[zoneStart - 1] > previousApex) {
        zoneStart--;
      }
      var peak = 0;
      for (var i = zoneStart; i <= zoneEnd; i++) {
        peak = math.max(peak, trace.brakes[i]);
      }
      braking = CornerBraking(
        startDistance: onRef[zoneStart],
        x: trace.xs[zoneStart],
        z: trace.zs[zoneStart],
        peakPercent: peak,
        zoneMeters: trace.distances[zoneEnd] - trace.distances[zoneStart],
      );
      entryKmh = trace.speedsKmh[zoneStart];
    } else {
      for (final i in inStretch) {
        if (i >= minIndex) break;
        entryKmh = math.max(entryKmh, trace.speedsKmh[i]);
      }
    }

    final exitAt = math.min(onRef[minIndex] + exitMeters, nextApex);
    final exitKmh = _interpolate(onRef, trace.speedsKmh, exitAt);
    return CornerPass(entryKmh: entryKmh, minKmh: minKmh, exitKmh: exitKmh, braking: braking);
  }

  /// Value of [ys] at [x] along the (non-decreasing) [xs].
  static double _interpolate(List<double> xs, List<double> ys, double x) {
    if (x <= xs.first) return ys.first;
    if (x >= xs.last) return ys.last;
    var lo = 0, hi = xs.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (xs[mid] <= x) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final span = xs[hi] - xs[lo];
    return span == 0 ? ys[hi] : ys[lo] + (ys[hi] - ys[lo]) * (x - xs[lo]) / span;
  }
}
