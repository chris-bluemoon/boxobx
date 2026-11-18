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
/// behind it, informed by real practice-session telemetry when
/// available (see PracticeFuelCalculator) at generation time.
class RaceStrategy {
  final List<PlannedPitStop> pitStops;

  /// Starting tire compound recommendation (before any pit stop).
  final String startingTireCompound;

  /// Overall strategy summary in plain English (e.g. "1-stop, switch
  /// to hards at lap 12 for the fuel save").
  final String summary;

  /// Assumed average fuel consumption percent-per-lap the strategy's
  /// pit-lap math was based on -- either the generic baseline, or real
  /// measured consumption from logged practice laps when enough data
  /// existed at generation time (see PitStopCalculator,
  /// PracticeFuelCalculator).
  final double assumedPercentPerLap;

  /// Total estimated time lost to pit stops across the whole race
  /// (pitStops.length * per-stop time loss), in seconds -- per-stop
  /// loss is either the driver's own measured value (see
  /// RaceBriefing.pitStopTimeSeconds, GT7's on-screen figure) or PitStopCalculator's generic
  /// default if nothing has been measured yet.
  final double totalEstimatedTimeLossSeconds;

  /// Whether totalEstimatedTimeLossSeconds was computed from the
  /// driver's own measured pit-stop time (true) or the generic default
  /// assumption (false) -- surfaced in the UI the same way
  /// assumedPercentPerLap's "measured vs assumed" badge works.
  final bool pitStopTimeIsMeasured;

  /// The round's practice stint tests done and planned when this
  /// strategy was generated (see TestPlan). Until all are done, the plan
  /// rests on assumptions (generic fuel use, the community tyre guide for
  /// the weather), not the driver's own laps.
  final int testsDone;
  final int testsPlanned;

  /// What the plan rests on, one line each (fuel, pit stop, each wet
  /// spell's tyre: measured or assumed) -- the "why" when it changes.
  final List<String> basis;

  /// GT7's fuel map (MFD) to run: 1 is full power; higher maps burn less
  /// fuel and give up some pace (see PitStopCalculator.fuelMapFactor).
  final int fuelMap;

  /// Built on the full set of practice stint tests.
  bool get validatedByPractice => testsPlanned > 0 && testsDone >= testsPlanned;

  RaceStrategy withPractice({required int done, required int planned}) => RaceStrategy(
    pitStops: pitStops,
    startingTireCompound: startingTireCompound,
    summary: summary,
    assumedPercentPerLap: assumedPercentPerLap,
    totalEstimatedTimeLossSeconds: totalEstimatedTimeLossSeconds,
    pitStopTimeIsMeasured: pitStopTimeIsMeasured,
    testsDone: done,
    testsPlanned: planned,
    basis: basis,
    fuelMap: fuelMap,
  );

  RaceStrategy copyWith({String? summary, List<String>? basis, int? fuelMap}) => RaceStrategy(
    pitStops: pitStops,
    startingTireCompound: startingTireCompound,
    summary: summary ?? this.summary,
    assumedPercentPerLap: assumedPercentPerLap,
    totalEstimatedTimeLossSeconds: totalEstimatedTimeLossSeconds,
    pitStopTimeIsMeasured: pitStopTimeIsMeasured,
    testsDone: testsDone,
    testsPlanned: testsPlanned,
    basis: basis ?? this.basis,
    fuelMap: fuelMap ?? this.fuelMap,
  );

  const RaceStrategy({
    required this.pitStops,
    required this.startingTireCompound,
    required this.summary,
    required this.assumedPercentPerLap,
    this.totalEstimatedTimeLossSeconds = 0.0,
    this.pitStopTimeIsMeasured = false,
    this.testsDone = 0,
    this.testsPlanned = 0,
    this.basis = const [],
    this.fuelMap = 1,
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
        testsDone: (map['testsDone'] as num?)?.toInt() ?? 0,
        testsPlanned: (map['testsPlanned'] as num?)?.toInt() ?? 0,
        basis: (map['basis'] as List?)?.cast<String>() ?? const [],
        fuelMap: (map['fuelMap'] as num?)?.toInt() ?? 1,
      );

  Map<String, dynamic> toMap() => {
        'pitStops': pitStops.map((p) => p.toMap()).toList(),
        'startingTireCompound': startingTireCompound,
        'summary': summary,
        'assumedPercentPerLap': assumedPercentPerLap,
        'totalEstimatedTimeLossSeconds': totalEstimatedTimeLossSeconds,
        'pitStopTimeIsMeasured': pitStopTimeIsMeasured,
        'testsDone': testsDone,
        'testsPlanned': testsPlanned,
        'basis': basis,
        'fuelMap': fuelMap,
      };
}
