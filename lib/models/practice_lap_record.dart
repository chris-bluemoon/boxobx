/// A single completed practice lap, logged with everything needed to
/// later compute real fuel-per-lap and tire-wear trends: the lap time,
/// which tire compound was mounted (GT7's telemetry has NO field for
/// this at all, so it comes from whatever the driver selected on the
/// dashboard's tire picker before going out), and the fuel percent at
/// the start/end of the lap.
class PracticeLapRecord {
  /// 1-indexed lap number within the practice session it was driven in
  /// (not cumulative across sessions -- just for display/ordering).
  final int lapNumber;

  /// Completed lap time in milliseconds (GT7's lastLapTimeMs).
  final int lapTimeMs;

  /// Tire compound mounted for this lap, as selected on the dashboard's
  /// tire picker at the time -- not measured by telemetry (GT7 doesn't
  /// expose it), so this is only as accurate as the driver keeping the
  /// picker in sync with what they actually fitted in-game.
  final String tireCompound;

  final double fuelPercentAtLapStart;
  final double fuelPercentAtLapEnd;

  /// Tire wear percentage at the END of this lap, as read directly off
  /// GT7's own in-game HUD/pause-menu tire display -- GT7's telemetry
  /// packet has no tire-wear field at all (same limitation as tire
  /// compound), so like tireCompound this is manual entry, not
  /// measured. Null if the driver didn't log it for this lap. Used to
  /// spot the "wear cliff" (grip falling off sharply, typically
  /// reported around 50% or 20% remaining in GT7) by cross-referencing
  /// against lapTimeMs across consecutive laps on the same compound.
  final double? tireWearPercent;

  /// How many upshifts during this lap were classified as short-shifts
  /// (shifted well before the power band -- see ShiftTiming.early),
  /// good (within the optimal window), or over-revs (held well past
  /// the optimal point -- ShiftTiming.late), via the same
  /// PowerBandConfig-based classification ShiftHistoryTracker already
  /// uses for the live dashboard gauge. Both short-shifting and
  /// over-revving burn more fuel per lap than a clean shift (more time
  /// spent off the engine's efficient operating range to cover the
  /// same distance), so these counts are a real input to how accurate
  /// a fuel-per-lap prediction from this lap's data actually is -- a
  /// lap with a lot of early/late shifts shouldn't be weighted the
  /// same as a clean one when predicting how many laps a stint will
  /// last.
  final int shortShiftCount;
  final int goodShiftCount;
  final int overRevShiftCount;

  /// When this lap was recorded (wall-clock), not in-game time --
  /// mainly for display ("logged 10 minutes ago") and for potential
  /// future pruning/sorting.
  final DateTime recordedAt;

  const PracticeLapRecord({
    required this.lapNumber,
    required this.lapTimeMs,
    required this.tireCompound,
    required this.fuelPercentAtLapStart,
    required this.fuelPercentAtLapEnd,
    this.tireWearPercent,
    this.shortShiftCount = 0,
    this.goodShiftCount = 0,
    this.overRevShiftCount = 0,
    required this.recordedAt,
  });

  /// Fuel percent actually consumed over this lap -- negative values
  /// (e.g. a refuel happened mid-lap) are left as-is rather than
  /// clamped, so callers can decide whether to exclude anomalous laps
  /// from an average rather than have bad data silently hidden here.
  double get fuelConsumedPercent => fuelPercentAtLapStart - fuelPercentAtLapEnd;

  /// Total upshifts recorded this lap, across all three
  /// classifications -- used to compute cleanShiftRatio below.
  int get totalShiftCount => shortShiftCount + goodShiftCount + overRevShiftCount;

  /// Fraction of this lap's upshifts that were classified as "good"
  /// (within the optimal power-band window), from 0.0 (every shift was
  /// early or late) to 1.0 (every shift was clean), or null if no
  /// upshifts were recorded at all this lap (e.g. a single-gear
  /// straight, or shift detection wasn't active). This is the signal
  /// ShiftAwareFuelCalculator uses to judge how much to trust this
  /// particular lap's fuel-per-lap reading: a lap with a low ratio
  /// burned more fuel than a clean lap would have purely from shift
  /// habit, independent of tire/fuel-map differences.
  double? get cleanShiftRatio => totalShiftCount == 0 ? null : goodShiftCount / totalShiftCount;

  String get formattedLapTime {
    final totalMs = lapTimeMs;
    final minutes = totalMs ~/ 60000;
    final seconds = (totalMs % 60000) / 1000;
    return '$minutes:${seconds.toStringAsFixed(3).padLeft(6, '0')}';
  }

  factory PracticeLapRecord.fromMap(Map<String, dynamic> map) => PracticeLapRecord(
        lapNumber: (map['lapNumber'] as num).toInt(),
        lapTimeMs: (map['lapTimeMs'] as num).toInt(),
        tireCompound: map['tireCompound'] as String,
        fuelPercentAtLapStart: (map['fuelPercentAtLapStart'] as num).toDouble(),
        fuelPercentAtLapEnd: (map['fuelPercentAtLapEnd'] as num).toDouble(),
        tireWearPercent: (map['tireWearPercent'] as num?)?.toDouble(),
        shortShiftCount: (map['shortShiftCount'] as num?)?.toInt() ?? 0,
        goodShiftCount: (map['goodShiftCount'] as num?)?.toInt() ?? 0,
        overRevShiftCount: (map['overRevShiftCount'] as num?)?.toInt() ?? 0,
        recordedAt: DateTime.parse(map['recordedAt'] as String),
      );

  Map<String, dynamic> toMap() => {
        'lapNumber': lapNumber,
        'lapTimeMs': lapTimeMs,
        'tireCompound': tireCompound,
        'fuelPercentAtLapStart': fuelPercentAtLapStart,
        'fuelPercentAtLapEnd': fuelPercentAtLapEnd,
        'tireWearPercent': tireWearPercent,
        'shortShiftCount': shortShiftCount,
        'goodShiftCount': goodShiftCount,
        'overRevShiftCount': overRevShiftCount,
        'recordedAt': recordedAt.toIso8601String(),
      };

  /// Returns a copy with tireWearPercent set -- used by the Practice
  /// Log screen's "log tire wear" action to attach a reading to an
  /// already-recorded lap after the fact (the driver typically checks
  /// the pause-menu tire display AFTER completing the lap, not during).
  PracticeLapRecord withTireWearPercent(double value) => PracticeLapRecord(
        lapNumber: lapNumber,
        lapTimeMs: lapTimeMs,
        tireCompound: tireCompound,
        fuelPercentAtLapStart: fuelPercentAtLapStart,
        fuelPercentAtLapEnd: fuelPercentAtLapEnd,
        tireWearPercent: value,
        shortShiftCount: shortShiftCount,
        goodShiftCount: goodShiftCount,
        overRevShiftCount: overRevShiftCount,
        recordedAt: recordedAt,
      );

  /// Returns a copy with a different lapNumber -- used by
  /// PracticeLapLogger.removeLap to renumber the remaining laps
  /// sequentially after a deletion, so there are never gaps/duplicates
  /// in the displayed lap numbers.
  PracticeLapRecord withLapNumber(int newLapNumber) => PracticeLapRecord(
        lapNumber: newLapNumber,
        lapTimeMs: lapTimeMs,
        tireCompound: tireCompound,
        fuelPercentAtLapStart: fuelPercentAtLapStart,
        fuelPercentAtLapEnd: fuelPercentAtLapEnd,
        tireWearPercent: tireWearPercent,
        shortShiftCount: shortShiftCount,
        goodShiftCount: goodShiftCount,
        overRevShiftCount: overRevShiftCount,
        recordedAt: recordedAt,
      );
}
