/// A dry tyre as the plan saw it: its lap (seconds), how many laps it
/// lasts, and its wear a lap (percent, if measured).
class RacePlanTyre {
  final String compound;
  final double lapSeconds;
  final int lifeLaps;
  final double? wearPerLap;

  const RacePlanTyre(this.compound, {required this.lapSeconds, required this.lifeLaps, this.wearPerLap});

  factory RacePlanTyre.fromMap(Map<String, dynamic> map) => RacePlanTyre(
    map['compound'] as String? ?? '',
    lapSeconds: (map['lapSeconds'] as num?)?.toDouble() ?? 0,
    lifeLaps: (map['lifeLaps'] as num?)?.toInt() ?? 999,
    wearPerLap: (map['wearPerLap'] as num?)?.toDouble(),
  );

  Map<String, dynamic> toMap() => {
    'compound': compound,
    'lapSeconds': lapSeconds,
    'lifeLaps': lifeLaps,
    if (wearPerLap != null) 'wearPerLap': wearPerLap,
  };
}

/// A fuel map the plan could run: fuel a lap (percent) and pace cost (a
/// share of the lap).
class RacePlanMap {
  final int map;
  final double perLap;
  final double lapTimeLoss;

  const RacePlanMap(this.map, {required this.perLap, required this.lapTimeLoss});

  factory RacePlanMap.fromMap(Map<String, dynamic> map) => RacePlanMap(
    (map['map'] as num?)?.toInt() ?? 1,
    perLap: (map['perLap'] as num?)?.toDouble() ?? 0,
    lapTimeLoss: (map['lapTimeLoss'] as num?)?.toDouble() ?? 0,
  );

  Map<String, dynamic> toMap() => {'map': map, 'perLap': perLap, 'lapTimeLoss': lapTimeLoss};
}

/// The figures a dry strategy was planned on (see PitStopCalculator), kept
/// with it, so the rest of the race can be planned again mid-race from
/// where the car is (see PitStopCalculator.replan) on the same numbers.
class RacePlanInputs {
  final int totalLaps;

  /// Fastest first.
  final List<RacePlanTyre> tyres;

  /// The measured maps (Map 1 first).
  final List<RacePlanMap> maps;

  /// A lap, seconds (what a map's pace cost is a share of).
  final double lapSeconds;
  final double pitLossSeconds;

  /// The brief's mandatory compound, if any.
  final String? mandatoryTyre;

  /// Fuel after a stop (the brief's starting fuel), percent.
  final double tankPercent;

  /// The brief's finish reserve, percent (0: half a lap on the map run).
  final double finishReservePercent;

  const RacePlanInputs({
    required this.totalLaps,
    required this.tyres,
    required this.maps,
    required this.lapSeconds,
    required this.pitLossSeconds,
    this.mandatoryTyre,
    required this.tankPercent,
    this.finishReservePercent = 0,
  });

  RacePlanTyre? tyre(String compound) => tyres.where((t) => t.compound == compound).firstOrNull;

  factory RacePlanInputs.fromMap(Map<String, dynamic> map) => RacePlanInputs(
    totalLaps: (map['totalLaps'] as num?)?.toInt() ?? 1,
    tyres: [for (final t in map['tyres'] as List? ?? const []) RacePlanTyre.fromMap(t as Map<String, dynamic>)],
    maps: [for (final m in map['maps'] as List? ?? const []) RacePlanMap.fromMap(m as Map<String, dynamic>)],
    lapSeconds: (map['lapSeconds'] as num?)?.toDouble() ?? 0,
    pitLossSeconds: (map['pitLossSeconds'] as num?)?.toDouble() ?? 0,
    mandatoryTyre: map['mandatoryTyre'] as String?,
    tankPercent: (map['tankPercent'] as num?)?.toDouble() ?? 100,
    finishReservePercent: (map['finishReservePercent'] as num?)?.toDouble() ?? 0,
  );

  Map<String, dynamic> toMap() => {
    'totalLaps': totalLaps,
    'tyres': [for (final t in tyres) t.toMap()],
    'maps': [for (final m in maps) m.toMap()],
    'lapSeconds': lapSeconds,
    'pitLossSeconds': pitLossSeconds,
    if (mandatoryTyre != null) 'mandatoryTyre': mandatoryTyre,
    'tankPercent': tankPercent,
    'finishReservePercent': finishReservePercent,
  };
}
