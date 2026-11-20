/// One corner of one lap against the round's time-trial best (see
/// CornerReport): the time lost or gained over the corner's stretch, and
/// what was different -- the brake point, the slowest point and the exit.
/// Kept on each stint and race lap, so the corners that cost the most can
/// be totted up over a race (see CornerLosses).
class CornerDelta {
  final int corner;

  /// Lost (+) or gained (-) over the corner's stretch of the lap, ms.
  final int ms;

  /// Metres later (+) or earlier (-) on the brakes; null unless both laps
  /// braked there.
  final int? brakeMeters;

  /// km/h higher (+) or lower (-) at the slowest point, and at the exit.
  final int minKmh;
  final int exitKmh;

  const CornerDelta({
    required this.corner,
    required this.ms,
    this.brakeMeters,
    this.minKmh = 0,
    this.exitKmh = 0,
  });

  /// Saved as a short list: [corner, ms, brake m or null, min km/h, exit km/h].
  List<int?> toList() => [corner, ms, brakeMeters, minKmh, exitKmh];

  factory CornerDelta.fromList(List l) => CornerDelta(
    corner: (l[0] as num).toInt(),
    ms: (l[1] as num).toInt(),
    brakeMeters: l.length > 2 ? (l[2] as num?)?.toInt() : null,
    minKmh: l.length > 3 ? (l[3] as num?)?.toInt() ?? 0 : 0,
    exitKmh: l.length > 4 ? (l[4] as num?)?.toInt() ?? 0 : 0,
  );
}
