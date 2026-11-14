import 'dart:math' as math;

import 'corner.dart';
import 'reference_lap.dart';

/// A timing line across the track: a point on the racing line and the
/// direction of travel there (unit vector, world X/Z). The car crosses
/// it going from behind the point to in front of it, near the point.
class SectorGate {
  final double x, z;
  final double dirX, dirZ;

  const SectorGate({required this.x, required this.z, required this.dirX, required this.dirZ});

  /// How far in front of the line (+) or behind it (-) a position is.
  double signedDistance(double px, double pz) => (px - x) * dirX + (pz - z) * dirZ;

  double distanceTo(double px, double pz) => math.sqrt(math.pow(px - x, 2) + math.pow(pz - z, 2));

  factory SectorGate.fromMap(Map<String, dynamic> m) => SectorGate(
    x: (m['x'] as num).toDouble(),
    z: (m['z'] as num).toDouble(),
    dirX: (m['dirX'] as num).toDouble(),
    dirZ: (m['dirZ'] as num).toDouble(),
  );

  Map<String, dynamic> toMap() => {'x': x, 'z': z, 'dirX': dirX, 'dirZ': dirZ};
}

/// One sample of the car's path: world X/Z, the race clock (seconds),
/// speed (km/h) and brake pedal (0-100).
typedef PathSample = ({double x, double z, double t, double v, double brake});

/// Our own sector lines for one circuit layout, learned from a lap the
/// driver drove there (GT7 sends no sector data). [start] is the
/// start/finish line; [gates] are the S1/S2 and S2/S3 lines, a third and
/// two thirds of the way round the lap by distance. A layout is
/// recognised by where the lap starts and which way it's driven, so a
/// reverse layout (same line, opposite direction) gets its own map.
class SectorMap {
  final SectorGate start;
  final List<SectorGate> gates;

  /// Fastest clean lap here, per car (GT7's car code) -- the live delta's
  /// reference. Replaced whenever a faster lap is driven in that car.
  final Map<int, ReferenceLap> references;

  /// The layout's corners, in lap order -- found once, from the first
  /// reference lap with speeds, so their numbering never changes (see
  /// CornerDetector).
  final List<Corner> corners;

  SectorMap({required this.start, required this.gates, Map<int, ReferenceLap>? references, List<Corner>? corners})
    : references = references ?? {},
      corners = corners ?? [];

  /// Positions within this distance (m) of a line count as being on it --
  /// keeps a different part of the track that happens to cross the
  /// line's extension from triggering it.
  static const double gateRadiusMeters = 40;

  /// How close (m) a lap's start must be to [start] to be this layout.
  static const double matchRadiusMeters = 80;

  /// Whether a lap starting at (x, z), heading (dirX, dirZ), is this layout.
  bool matches(double x, double z, double dirX, double dirZ) =>
      start.distanceTo(x, z) <= matchRadiusMeters && dirX * start.dirX + dirZ * start.dirZ > 0.5;

  /// Learns the lines from one complete lap's [path] (start/finish to
  /// start/finish). Null if the path is too short or broken (a reset or
  /// teleport: a jump of more than 60 m between samples).
  static SectorMap? learn(List<PathSample> path) {
    if (path.length < 120) return null;
    final cumulative = <double>[0];
    for (var i = 1; i < path.length; i++) {
      final step = math.sqrt(math.pow(path[i].x - path[i - 1].x, 2) + math.pow(path[i].z - path[i - 1].z, 2));
      if (step > 60) return null;
      cumulative.add(cumulative.last + step);
    }
    final length = cumulative.last;
    if (length < 500) return null;

    SectorGate gateAt(double distance) {
      var i = cumulative.indexWhere((d) => d >= distance);
      if (i < 0) i = path.length - 1;
      return _gate(path, i);
    }

    return SectorMap(start: _gate(path, 0), gates: [gateAt(length / 3), gateAt(length * 2 / 3)]);
  }

  /// A line at sample [i], facing along the path around it.
  static SectorGate _gate(List<PathSample> path, int i) {
    const span = 6;
    final a = path[math.max(0, i - span)];
    final b = path[math.min(path.length - 1, i + span)];
    final dx = b.x - a.x, dz = b.z - a.z;
    final len = math.sqrt(dx * dx + dz * dz);
    return SectorGate(x: path[i].x, z: path[i].z, dirX: len == 0 ? 1 : dx / len, dirZ: len == 0 ? 0 : dz / len);
  }

  /// When the car crossed [gate] going from [a] to [b], interpolated
  /// between the two samples; null if it didn't.
  static double? crossingTime(SectorGate gate, PathSample a, PathSample b) {
    final sa = gate.signedDistance(a.x, a.z);
    final sb = gate.signedDistance(b.x, b.z);
    if (!(sa < 0 && sb >= 0)) return null;
    if (gate.distanceTo(b.x, b.z) > gateRadiusMeters && gate.distanceTo(a.x, a.z) > gateRadiusMeters) return null;
    return a.t + (b.t - a.t) * (-sa / (sb - sa));
  }

  factory SectorMap.fromMap(Map<String, dynamic> m) => SectorMap(
    start: SectorGate.fromMap(m['start'] as Map<String, dynamic>),
    gates: [for (final g in m['gates'] as List) SectorGate.fromMap(g as Map<String, dynamic>)],
    references: {
      for (final e in ((m['references'] as Map?) ?? {}).entries)
        int.parse(e.key as String): ReferenceLap.fromMap(e.value as Map<String, dynamic>),
    },
    corners: [for (final c in (m['corners'] as List?) ?? const []) Corner.fromMap(c as Map<String, dynamic>)],
  );

  Map<String, dynamic> toMap() => {
    'start': start.toMap(),
    'gates': [for (final g in gates) g.toMap()],
    'references': {for (final e in references.entries) '${e.key}': e.value.toMap()},
    'corners': [for (final c in corners) c.toMap()],
  };
}
