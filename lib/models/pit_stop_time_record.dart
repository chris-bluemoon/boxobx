/// A single manually-measured pit-stop time loss, entered by the
/// driver after comparing an in-lap + stationary time + out-lap
/// sequence against a normal lap. GT7's telemetry has no pit-lane
/// entry/exit flag at all, so (like tire compound and tire wear %)
/// this is manual entry rather than something the app detects
/// automatically.
class PitStopTimeRecord {
  /// Total time lost to the pit stop, in seconds -- the FULL delta
  /// (in-lap + stationary + out-lap combined) vs. what a normal lap
  /// would have taken, not just the stationary portion. This is the
  /// number PitStopCalculator actually needs: how much slower doing a
  /// stop is than just staying out.
  final double totalTimeLossSeconds;

  /// Tire compound that was fitted during this stop (what's being
  /// measured for -- a Soft-to-Hard stop may take a different amount
  /// of stationary time than Hard-to-Hard, if GT7 models that).
  final String tireCompoundFitted;

  /// The car's refuel rate, in liters/second, as separately observed
  /// (e.g. by timing how long the fuel bar takes to fill) -- kept here
  /// per-record since a driver might re-measure it, but typically the
  /// same across stops for a given car/league refueling-speed setting.
  final double? refuelRateLitersPerSecond;

  final DateTime recordedAt;

  const PitStopTimeRecord({
    required this.totalTimeLossSeconds,
    required this.tireCompoundFitted,
    this.refuelRateLitersPerSecond,
    required this.recordedAt,
  });

  factory PitStopTimeRecord.fromMap(Map<String, dynamic> map) => PitStopTimeRecord(
        totalTimeLossSeconds: (map['totalTimeLossSeconds'] as num).toDouble(),
        tireCompoundFitted: map['tireCompoundFitted'] as String,
        refuelRateLitersPerSecond: (map['refuelRateLitersPerSecond'] as num?)?.toDouble(),
        recordedAt: DateTime.parse(map['recordedAt'] as String),
      );

  Map<String, dynamic> toMap() => {
        'totalTimeLossSeconds': totalTimeLossSeconds,
        'tireCompoundFitted': tireCompoundFitted,
        'refuelRateLitersPerSecond': refuelRateLitersPerSecond,
        'recordedAt': recordedAt.toIso8601String(),
      };
}
