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

  /// Upshift counts for this lap by timing (early / good / late, per
  /// PowerBandConfig). Still recorded and saved, but currently unused:
  /// shift quality was taken out of the strategy calculation and the
  /// practice log on 2026-11-14, pending a rethink.
  final int shortShiftCount;
  final int goodShiftCount;
  final int overRevShiftCount;

  /// When this lap was recorded (wall-clock), not in-game time --
  /// mainly for display ("logged 10 minutes ago") and for potential
  /// future pruning/sorting.
  final DateTime recordedAt;

  /// True if a pit stop was detected on this lap or the lap before it
  /// (see PitStopTracker). Pit laps are much slower and may show
  /// negative fuel use (a refuel), so they're excluded from lap-time
  /// and fuel-per-lap averages.
  final bool isPitLap;

  /// Which stint of the round this lap belongs to (1, 2, ...): a run on
  /// one set of tyres and one fuel load, so wear and fuel use can be
  /// measured per stint (see StintSummary). 0 = logged before stints
  /// existed.
  final int stintNumber;

  /// True if logged in Race Mode rather than Practice Mode (see
  /// AppMode) -- laps are recorded in both.
  final bool isRaceLap;

  /// Which planned test (see TestPlan) the driver said this stint was
  /// for, by its number in the plan; null = not a test stint. Set only
  /// by the driver starting a test from the dashboard -- never inferred.
  final int? testNumber;

  /// Set on the last recorded lap of a test stint when the app called
  /// the test complete (see PracticeLapLogger.completeActiveTest) --
  /// the target can be reached mid-lap, after the last saved lap.
  final bool testTargetReached;

  /// Race Mode laps: which race of the round this lap belongs to (1, 2,
  /// ...) -- a race is one run in Race Mode from going out on track to
  /// leaving it, test race or real (see RaceReport). Null otherwise.
  final int? raceNumber;

  /// Race position at the end of this lap (from the leaderboard), if read.
  final int? position;

  /// S1/S2/S3 times (ms) from our own sector lines (see
  /// SectorCalculator), adding up to [lapTimeMs]; null if not split.
  final List<int>? sectorsMs;

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
    this.isPitLap = false,
    this.stintNumber = 0,
    this.isRaceLap = false,
    this.testNumber,
    this.testTargetReached = false,
    this.raceNumber,
    this.position,
    this.sectorsMs,
  });

  /// Fuel percent actually consumed over this lap -- negative values
  /// (e.g. a refuel happened mid-lap) are left as-is rather than
  /// clamped, so callers can decide whether to exclude anomalous laps
  /// from an average rather than have bad data silently hidden here.
  double get fuelConsumedPercent => fuelPercentAtLapStart - fuelPercentAtLapEnd;

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
    isPitLap: map['isPitLap'] as bool? ?? false,
    stintNumber: (map['stintNumber'] as num?)?.toInt() ?? 0,
    isRaceLap: map['isRaceLap'] as bool? ?? false,
    testNumber: (map['testNumber'] as num?)?.toInt(),
    testTargetReached: map['testTargetReached'] as bool? ?? false,
    raceNumber: (map['raceNumber'] as num?)?.toInt(),
    position: (map['position'] as num?)?.toInt(),
    sectorsMs: (map['sectorsMs'] as List?)?.map((s) => (s as num).toInt()).toList(),
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
    'isPitLap': isPitLap,
    'stintNumber': stintNumber,
    'isRaceLap': isRaceLap,
    'testNumber': testNumber,
    'testTargetReached': testTargetReached,
    'raceNumber': raceNumber,
    'position': position,
    'sectorsMs': sectorsMs,
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
    isPitLap: isPitLap,
    stintNumber: stintNumber,
    isRaceLap: isRaceLap,
    testNumber: testNumber,
    testTargetReached: testTargetReached,
    raceNumber: raceNumber,
    position: position,
    sectorsMs: sectorsMs,
  );

  /// Returns a copy marked as the lap on which its test was called
  /// complete.
  PracticeLapRecord withTestTargetReached() => PracticeLapRecord(
    lapNumber: lapNumber,
    lapTimeMs: lapTimeMs,
    tireCompound: tireCompound,
    fuelPercentAtLapStart: fuelPercentAtLapStart,
    fuelPercentAtLapEnd: fuelPercentAtLapEnd,
    tireWearPercent: tireWearPercent,
    shortShiftCount: shortShiftCount,
    goodShiftCount: goodShiftCount,
    overRevShiftCount: overRevShiftCount,
    recordedAt: recordedAt,
    isPitLap: isPitLap,
    stintNumber: stintNumber,
    isRaceLap: isRaceLap,
    testNumber: testNumber,
    testTargetReached: true,
    raceNumber: raceNumber,
    position: position,
    sectorsMs: sectorsMs,
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
    isPitLap: isPitLap,
    stintNumber: stintNumber,
    isRaceLap: isRaceLap,
    testNumber: testNumber,
    testTargetReached: testTargetReached,
    raceNumber: raceNumber,
    position: position,
    sectorsMs: sectorsMs,
  );
}
