/// A single planned pit stop within a RaceStrategy.
class PlannedPitStop {
  /// 1-indexed lap this stop should happen on.
  final int lap;

  /// Tire compound to fit at this stop (from the briefing's
  /// availableTireCompounds).
  final String tireCompound;

  /// Short rationale for why this specific lap/compound, so the driver
  /// understands the reasoning rather than just following a number
  /// blindly (e.g. "tires falling off past lap 10 on this compound").
  final String reasoning;

  const PlannedPitStop({
    required this.lap,
    required this.tireCompound,
    required this.reasoning,
  });

  factory PlannedPitStop.fromMap(Map<String, dynamic> map) => PlannedPitStop(
        lap: (map['lap'] as num).toInt(),
        tireCompound: map['tireCompound'] as String? ?? '',
        reasoning: map['reasoning'] as String? ?? '',
      );

  Map<String, dynamic> toMap() => {
        'lap': lap,
        'tireCompound': tireCompound,
        'reasoning': reasoning,
      };
}

/// The AI-generated race strategy produced by RaceStrategistService from
/// a RaceBriefing -- a recommended pit-stop plan plus the reasoning
/// behind it, generated once pre-race and then checked against real
/// practice-session telemetry (see StrategyValidator).
class RaceStrategy {
  final List<PlannedPitStop> pitStops;

  /// Starting tire compound recommendation (before any pit stop).
  final String startingTireCompound;

  /// Overall strategy summary in plain English (e.g. "1-stop, switch
  /// to hards at lap 12 for the fuel save").
  final String summary;

  /// Assumed average fuel consumption percent-per-lap the strategy's
  /// pit-lap math was based on -- this is what StrategyValidator
  /// compares real practice-session consumption against to flag if the
  /// plan's assumption was wrong.
  final double assumedPercentPerLap;

  /// Total estimated time lost to pit stops across the whole race
  /// (pitStops.length * per-stop time loss), in seconds -- per-stop
  /// loss is either the driver's own measured value (see
  /// PitStopTimeRecord/PitStopTimeStore) or PitStopCalculator's generic
  /// default if nothing has been measured yet.
  final double totalEstimatedTimeLossSeconds;

  /// Whether totalEstimatedTimeLossSeconds was computed from the
  /// driver's own measured pit-stop time (true) or the generic default
  /// assumption (false) -- surfaced in the UI the same way
  /// assumedPercentPerLap's "measured vs assumed" badge works.
  final bool pitStopTimeIsMeasured;

  const RaceStrategy({
    required this.pitStops,
    required this.startingTireCompound,
    required this.summary,
    required this.assumedPercentPerLap,
    this.totalEstimatedTimeLossSeconds = 0.0,
    this.pitStopTimeIsMeasured = false,
  });

  factory RaceStrategy.fromMap(Map<String, dynamic> map) => RaceStrategy(
        pitStops: (map['pitStops'] as List? ?? [])
            .map((e) => PlannedPitStop.fromMap(e as Map<String, dynamic>))
            .toList(),
        startingTireCompound: map['startingTireCompound'] as String? ?? '',
        summary: map['summary'] as String? ?? '',
        assumedPercentPerLap: (map['assumedPercentPerLap'] as num?)?.toDouble() ?? 0.0,
        totalEstimatedTimeLossSeconds: (map['totalEstimatedTimeLossSeconds'] as num?)?.toDouble() ?? 0.0,
        pitStopTimeIsMeasured: map['pitStopTimeIsMeasured'] as bool? ?? false,
      );

  Map<String, dynamic> toMap() => {
        'pitStops': pitStops.map((p) => p.toMap()).toList(),
        'startingTireCompound': startingTireCompound,
        'summary': summary,
        'assumedPercentPerLap': assumedPercentPerLap,
        'totalEstimatedTimeLossSeconds': totalEstimatedTimeLossSeconds,
        'pitStopTimeIsMeasured': pitStopTimeIsMeasured,
      };
}
