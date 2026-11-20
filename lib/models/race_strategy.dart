import 'race_plan_inputs.dart';

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

  /// The fuel map for the stint after this stop (1 is full power).
  final int fuelMap;

  const PlannedPitStop({
    required this.lap,
    required this.tireCompound,
    required this.reasoning,
    this.fuelMap = 1,
  });

  /// [defaultFuelMap]: for a strategy saved before each stop had its own
  /// map -- the whole race ran on one, the strategy's.
  factory PlannedPitStop.fromMap(Map<String, dynamic> map, {int defaultFuelMap = 1}) => PlannedPitStop(
        lap: (map['lap'] as num).toInt(),
        tireCompound: map['tireCompound'] as String? ?? '',
        reasoning: map['reasoning'] as String? ?? '',
        fuelMap: (map['fuelMap'] as num?)?.toInt() ?? defaultFuelMap,
      );

  Map<String, dynamic> toMap() => {
        'lap': lap,
        'tireCompound': tireCompound,
        'reasoning': reasoning,
        'fuelMap': fuelMap,
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

  /// GT7's fuel map (MFD) to start on: 1 is full power; higher maps burn
  /// less fuel and give up some pace (see PitStopCalculator.fuelMapFactor).
  /// Each stop says the map for the stint after it
  /// ([PlannedPitStop.fuelMap]); [assumedPercentPerLap] is on this one.
  final int fuelMap;

  /// Each stint's fuel map, in race order.
  List<int> get stintMaps => [fuelMap, for (final p in pitStops) p.fuelMap];

  /// True if any stint runs a leaner map than Map 1.
  bool get usesLeanMap => stintMaps.any((m) => m > 1);

  /// A leaner fuel map that might save a pit stop, worth a stint test to
  /// measure (see PitStopCalculator.calculate) -- null if none could.
  final int? fuelMapToTest;

  /// The second-best plan -- the quicker alternative to switch to
  /// mid-race (see [planC] and PitStopCalculator.calculate). Null if
  /// there's none (or a wet race).
  final RaceStrategy? planB;

  /// The other alternative, slower than Plan B: when Plan A runs one tyre
  /// and more are allowed, there are two -- a different number of stops
  /// or set of tyres, and the quickest on two or more tyres (see
  /// PitStopCalculator.calculate). Null if there's only one.
  final RaceStrategy? planC;

  /// Plan B and Plan C, those there are, with their letters.
  List<(String, RaceStrategy)> get alternatives => [if (planB case final b?) ('B', b), if (planC case final c?) ('C', c)];

  /// On a Plan B: about how much slower over the race than Plan A.
  final double? secondsBehindPlanA;

  /// [secondsBehindPlanA] in short: "+24s", "+1m 05s" (null if none).
  String? get behindPlanALabel {
    final behind = secondsBehindPlanA;
    if (behind == null) return null;
    final s = behind.round();
    return s < 60 ? '+${s}s' : '+${s ~/ 60}m ${(s % 60).toString().padLeft(2, '0')}s';
  }

  /// The figures the plan was made on, to plan the rest of the race again
  /// mid-race (see PitStopCalculator.replan). Null for a wet race.
  final RacePlanInputs? inputs;

  /// Each stint's tyre, in race order.
  List<String> get stintTyres => [startingTireCompound, for (final p in pitStops) p.tireCompound];

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
    fuelMapToTest: fuelMapToTest,
    planB: planB,
    planC: planC,
    secondsBehindPlanA: secondsBehindPlanA,
    inputs: inputs,
  );

  RaceStrategy copyWith({String? summary, List<String>? basis, int? fuelMap, int? fuelMapToTest, List<PlannedPitStop>? pitStops}) => RaceStrategy(
    pitStops: pitStops ?? this.pitStops,
    startingTireCompound: startingTireCompound,
    summary: summary ?? this.summary,
    assumedPercentPerLap: assumedPercentPerLap,
    totalEstimatedTimeLossSeconds: totalEstimatedTimeLossSeconds,
    pitStopTimeIsMeasured: pitStopTimeIsMeasured,
    testsDone: testsDone,
    testsPlanned: testsPlanned,
    basis: basis ?? this.basis,
    fuelMap: fuelMap ?? this.fuelMap,
    fuelMapToTest: fuelMapToTest ?? this.fuelMapToTest,
    planB: planB,
    planC: planC,
    secondsBehindPlanA: secondsBehindPlanA,
    inputs: inputs,
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
    this.fuelMapToTest,
    this.planB,
    this.planC,
    this.secondsBehindPlanA,
    this.inputs,
  });

  factory RaceStrategy.fromMap(Map<String, dynamic> map) => RaceStrategy(
        pitStops: (map['pitStops'] as List? ?? [])
            .map((e) => PlannedPitStop.fromMap(e as Map<String, dynamic>, defaultFuelMap: (map['fuelMap'] as num?)?.toInt() ?? 1))
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
        fuelMapToTest: (map['fuelMapToTest'] as num?)?.toInt(),
        planB: map['planB'] is Map<String, dynamic> ? RaceStrategy.fromMap(map['planB'] as Map<String, dynamic>) : null,
        planC: map['planC'] is Map<String, dynamic> ? RaceStrategy.fromMap(map['planC'] as Map<String, dynamic>) : null,
        secondsBehindPlanA: (map['secondsBehindPlanA'] as num?)?.toDouble(),
        inputs: map['inputs'] is Map<String, dynamic> ? RacePlanInputs.fromMap(map['inputs'] as Map<String, dynamic>) : null,
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
        if (fuelMapToTest != null) 'fuelMapToTest': fuelMapToTest,
        if (planB != null) 'planB': planB!.toMap(),
        if (planC != null) 'planC': planC!.toMap(),
        if (secondsBehindPlanA != null) 'secondsBehindPlanA': secondsBehindPlanA,
        if (inputs != null) 'inputs': inputs!.toMap(),
      };
}
