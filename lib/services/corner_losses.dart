import '../models/corner_delta.dart';
import '../models/practice_lap_record.dart';

/// One corner over a run of laps against the time-trial best.
class CornerLoss {
  final int corner;

  /// Laps it's measured over.
  final int laps;

  /// Typical (median) time lost (+) or gained (-) per lap, ms.
  final int medianMs;

  /// Its share of the whole lap's typical gap, percent (null when the
  /// laps weren't slower overall).
  final double? shareOfGapPercent;

  /// Typical brake point (m later + / earlier -; null if rarely both
  /// braked), slowest-point and exit speed difference (km/h).
  final int? brakeMeters;
  final int minKmh;
  final int exitKmh;

  const CornerLoss({
    required this.corner,
    required this.laps,
    required this.medianMs,
    this.shareOfGapPercent,
    this.brakeMeters,
    this.minKmh = 0,
    this.exitKmh = 0,
  });

  /// e.g. "C7: 0.42 s a lap (31% of the gap), braking 15 m earlier,
  /// 6 km/h slower at the apex".
  String describe() {
    final parts = <String>[
      'C$corner: ${(medianMs.abs() / 1000).toStringAsFixed(2)} s a lap ${medianMs >= 0 ? 'lost' : 'gained'}'
          '${shareOfGapPercent == null || medianMs <= 0 ? '' : ' (${shareOfGapPercent!.round()}% of the gap)'}',
      ...whatsDifferent(),
    ];
    return parts.join(', ');
  }

  /// The differences worth saying, e.g. ["braking 15 m earlier",
  /// "6 km/h slower at the apex"].
  List<String> whatsDifferent() => [
    if (brakeMeters case final b? when b.abs() >= CornerLosses.brakeMetersWorthSaying)
      'braking ${b.abs()} m ${b < 0 ? 'earlier' : 'later'}',
    if (minKmh.abs() >= CornerLosses.kmhWorthSaying) '${minKmh.abs()} km/h ${minKmh < 0 ? 'slower' : 'faster'} at the apex',
    if (exitKmh.abs() >= CornerLosses.kmhWorthSaying) '${exitKmh.abs()} km/h ${exitKmh < 0 ? 'slower' : 'faster'} on exit',
  ];
}

/// Where a run of laps (a race, a stint) loses time against the round's
/// time-trial best, corner by corner: each lap's CornerDelta, typical
/// (median) per corner so one messy lap doesn't skew it. Race laps carry
/// fuel and worn tyres, so they're slower everywhere -- what matters is
/// which corners take the biggest share.
class CornerLosses {
  /// A corner needs this many laps to be judged.
  static const int minLaps = 3;

  /// A lap losing more than this in one corner had a moment there (an
  /// off, a spin, traffic) -- left out.
  static const int incidentMs = 2500;

  static const int brakeMetersWorthSaying = 5;
  static const int kmhWorthSaying = 3;

  final List<CornerLoss> corners;

  /// Laps used, and their typical whole-lap gap to the time-trial best.
  final int laps;
  final int? medianLapGapMs;

  const CornerLosses({this.corners = const [], this.laps = 0, this.medianLapGapMs});

  bool get isEmpty => corners.isEmpty;

  /// Biggest losses first, only those losing time.
  List<CornerLoss> get worst => [
    for (final c in corners)
      if (c.medianMs > 0) c,
  ]..sort((a, b) => b.medianMs.compareTo(a.medianMs));

  static CornerLosses fromLaps(List<PracticeLapRecord> laps) {
    final usable = [
      for (final lap in laps)
        if (!lap.isPitLap && lap.spinCount == 0 && (lap.cornerDeltas?.isNotEmpty ?? false))
          if (!lap.cornerDeltas!.any((c) => c.ms > incidentMs)) lap,
    ];
    if (usable.length < minLaps) return const CornerLosses();

    final byCorner = <int, List<CornerDelta>>{};
    for (final lap in usable) {
      for (final c in lap.cornerDeltas!) {
        byCorner.putIfAbsent(c.corner, () => []).add(c);
      }
    }
    final lapGap = _median([
      for (final lap in usable) lap.cornerDeltas!.fold<int>(0, (sum, c) => sum + c.ms).toDouble(),
    ]).round();

    final corners = <CornerLoss>[];
    for (final MapEntry(key: corner, value: passes) in byCorner.entries) {
      if (passes.length < minLaps) continue;
      final ms = _median([for (final p in passes) p.ms.toDouble()]).round();
      final brakes = [
        for (final p in passes)
          if (p.brakeMeters != null) p.brakeMeters!.toDouble(),
      ];
      corners.add(
        CornerLoss(
          corner: corner,
          laps: passes.length,
          medianMs: ms,
          shareOfGapPercent: lapGap > 0 ? ms / lapGap * 100 : null,
          brakeMeters: brakes.length * 2 >= passes.length ? _median(brakes).round() : null,
          minKmh: _median([for (final p in passes) p.minKmh.toDouble()]).round(),
          exitKmh: _median([for (final p in passes) p.exitKmh.toDouble()]).round(),
        ),
      );
    }
    corners.sort((a, b) => a.corner.compareTo(b.corner));
    return CornerLosses(corners: corners, laps: usable.length, medianLapGapMs: lapGap);
  }

  /// For Boxington: the three corners costing the most.
  List<String> toPrompt({int top = 3}) => [for (final c in worst.take(top)) c.describe()];

  static double _median(List<double> values) {
    if (values.isEmpty) return 0;
    final v = [...values]..sort();
    return v.length.isOdd ? v[v.length ~/ 2] : (v[v.length ~/ 2 - 1] + v[v.length ~/ 2]) / 2;
  }
}
