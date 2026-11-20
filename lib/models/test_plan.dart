import 'practice_lap_record.dart';
import 'race_briefing.dart';
import 'race_strategy.dart';
import 'weather_forecast.dart';
import '../services/pit_stop_calculator.dart';
import '../services/practice_fuel_calculator.dart';

enum TestStintKind {
  /// Full tank, run the tyres down to the wear target -- tyre life,
  /// pace drop-off, fuel per lap.
  long,

  /// Light fuel, a few laps on fresh tyres -- how much faster the car is
  /// light, compared with the same compound's full-tank stint.
  lowFuel,

  /// A few laps in one of the brief's rain presets, on one of the two
  /// tyres that weather could call for -- run in pairs, so the race's
  /// tyre calls have measured pace to go on (see WetPaceTable).
  wet,

  /// A few full-tank laps on a leaner fuel map the strategy thinks might
  /// save a pit stop (RaceStrategy.fuelMapToTest): what it really saves
  /// and costs, against the Map 1 long stint on the same tyre.
  fuelMap,

  /// The full race distance, run to the generated strategy: its start
  /// tyre and fuel, pitting where the Race Brief says. Carries on through
  /// the stops (one test over several stints).
  race,
}

/// One stint the driver is asked to run (see [TestPlan]).
class PlannedTestStint {
  /// 1-based position in the plan.
  final int number;
  final TestStintKind kind;

  /// Display name as used by the dashboard tyre picker, e.g. "Racing Soft".
  final String compound;
  final double startFuelPercent;

  /// Long stints: stop once the tyres have this much grip left.
  final double? stopAtWearRemainingPercent;

  /// Low-fuel and wet stints: how many laps to run. Long stints: the
  /// most laps worth running -- one tank, or the race distance if a tank
  /// lasts longer (null when the fuel use isn't known yet).
  final int? laps;

  /// The fuel map to run it on: Map 1, the baseline everything is
  /// measured against -- except a fuel map test (its own map) and the
  /// full race test (the strategy's, as raced).
  final int fuelMap;

  /// Long stints: [laps] is the race distance (a tank outlasts the race),
  /// not one tank.
  final bool lapsAreRaceDistance;

  /// Wet stints: the GT7 rain preset to set in the lobby ("R06"); the
  /// stint's laps are tagged with it. Null = dry.
  final String? weather;

  /// Wet stints: the tyre it's compared against in the same weather.
  final String? comparedWith;

  /// The full race test: the strategy's stops (each with the tyre to fit
  /// and the map for the next stint) -- null before a strategy is
  /// generated.
  final List<PlannedPitStop>? raceStops;

  /// The full race test: each stint's fuel map, in race order.
  List<int> get stintMaps => [fuelMap, for (final p in raceStops ?? const <PlannedPitStop>[]) p.fuelMap];

  const PlannedTestStint({
    required this.number,
    required this.kind,
    required this.compound,
    required this.startFuelPercent,
    this.stopAtWearRemainingPercent,
    this.laps,
    this.weather,
    this.comparedWith,
    this.lapsAreRaceDistance = false,
    this.fuelMap = 1,
    this.raceStops,
  });

  PlannedTestStint renumbered(int n, {int? fuelMap}) => PlannedTestStint(
    number: n,
    kind: kind,
    compound: compound,
    startFuelPercent: startFuelPercent,
    stopAtWearRemainingPercent: stopAtWearRemainingPercent,
    laps: laps,
    weather: weather,
    comparedWith: comparedWith,
    lapsAreRaceDistance: lapsAreRaceDistance,
    // Only the full race test follows the strategy's map; the rest are
    // Map 1 (the baseline) or, a fuel map test, its own.
    fuelMap: kind == TestStintKind.race ? (fuelMap ?? this.fuelMap) : this.fuelMap,
    raceStops: raceStops,
  );

  /// Short name for the compound ("Soft", "Medium"...).
  String get compoundShort => _short(compound);

  static String _short(String compound) => switch (compound) {
    'Heavy Wet' => 'Wets',
    'Intermediate' => 'Inters',
    _ => compound.replaceFirst('Racing ', ''),
  };

  /// "R06 Thick Cloud with Rain".
  String? get weatherName => weather == null ? null : '$weather ${WeatherSlot(weather!).name}';

  /// e.g. "Soft · 100% fuel · Map 1 · 5 laps (or until 90% worn or fuel < 5%)" /
  /// "Soft · 55% fuel · Map 1 · 2 laps".
  String get target => targetWith(null);

  /// [ranOnMap]: the map it was actually run on, once done (its laps
  /// say) -- shown in place of the planned one.

  /// [target], with how many laps the tyres are expected to last
  /// ([wearLaps], from a measured wear rate) when that's the limit: a
  /// long stint's laps are a tank (or the race), so the wear figure only
  /// shows when the tyres should go first.
  String targetWith(int? wearLaps, {int? ranOnMap}) {
    final fuel = '${startFuelPercent.toStringAsFixed(0)}% fuel · Map ${ranOnMap ?? fuelMap}';
    final worn = '${(100 - (stopAtWearRemainingPercent ?? 0)).toStringAsFixed(0)}% worn or fuel < ${TestPlan.fuelOutPercent.toStringAsFixed(0)}%';
    return switch (kind) {
      TestStintKind.long => laps == null
          ? '$compoundShort · $fuel · until $worn${wearLaps == null ? '' : ' (about $wearLaps laps)'}'
          : wearLaps != null && wearLaps < laps!
          ? '$compoundShort · $fuel · until $worn, about $wearLaps laps'
          : '$compoundShort · $fuel · $laps laps (or until $worn)',
      TestStintKind.lowFuel || TestStintKind.fuelMap => '$compoundShort · $fuel · $laps laps',
      TestStintKind.wet => '$compoundShort · $weather rain · $fuel · $laps laps',
      TestStintKind.race => 'Full race · $laps laps · start on $compoundShort · $fuel · ${_raceStopsText()}',
    };
  }

  /// The full race test's stops: "lap 4: box for Softs · Map 2 · lap 9:
  /// box for Softs · Map 1" (the map named where it changes).
  String _raceStopsText() {
    final stops = raceStops;
    if (stops == null) return 'change tyres when the track calls for it';
    if (stops.isEmpty) return 'no stops';
    final maps = stintMaps;
    return [
      for (final (i, p) in stops.indexed)
        'lap ${p.lap}: box for ${_plural(_short(p.tireCompound))}${p.fuelMap != maps[i] ? ' · Map ${p.fuelMap}' : ''}',
    ].join(' · ');
  }

  static String _plural(String tyre) => tyre.endsWith('s') ? tyre : '${tyre}s';

  /// What this stint tells us, for the plan screen.
  String get purpose => switch (kind) {
    TestStintKind.long => 'Tyre life and drop-off, fuel per lap',
    TestStintKind.lowFuel => 'Fuel-weight effect (light vs full-tank pace)',
    TestStintKind.fuelMap => 'Fuel Map $fuelMap: the fuel it saves and the pace it costs -- could it save a pit stop?',
    TestStintKind.wet => '$compoundShort vs ${_short(comparedWith!)} in $weatherName',
    TestStintKind.race => 'A full race in the race weather: fuel, wear and pace for the next strategy (set the lobby to the race settings)',
  };
}

/// The stints to run in practice for a round. A wet race (the brief's
/// weather has rain that needs Inters or Wets) gets wet-pace pairs at
/// the brief's own rain presets -- see [TestPlan.wetStints] -- and the
/// dry long stints only if the dry running is most of the race.
///
/// A dry race: the stints so the strategy has
/// everything it needs per compound: one long stint per allowed dry
/// compound -- all from a full tank so they compare like-for-like, run
/// until the tyres are 90% worn (well past where GT7 grip falls away, so
/// the stint records the drop-off and the laps after it), or the fuel
/// runs low -- then a short low-fuel run on the softest
/// compound for the fuel-weight effect. Once the fuel use is known, each
/// long stint is capped at one tank (or the race distance) -- see
/// [TestPlan.fromBriefing].
class TestPlan {
  static const double longStintStartFuelPercent = 100;
  static const double wearTargetRemainingPercent = 10;

  /// A long stint also ends when the fuel gets this low (see
  /// TestPlanTracker.stopReason).
  static const double fuelOutPercent = 5;
  static const double lowFuelStartPercent = 20;
  static const int lowFuelLaps = 4;

  /// Fuel kept back on a planned stint: half a lap (as the strategy).
  static const double reserveLaps = 0.5;
  static const int wetLaps = 4;
  static const int fuelMapTestLaps = 3;
  static const double wetStartFuelPercent = 100;


  /// The leaner map a fuel map test has been run on in [laps], if any --
  /// so the test stays in the plan (and the tests keep their numbers)
  /// once it's done, whatever the strategy then makes of it.
  /// The round's test plan, sized on the fuel this round's practice
  /// [laps] have measured (Map 1), once there's enough of them -- so the
  /// tests resize after each stint, without regenerating the strategy --
  /// else on [strategy]'s figure. The full race test runs [strategy]'s
  /// stops and maps.
  static TestPlan forRound(RaceBriefing briefing, RaceStrategy? strategy, List<PracticeLapRecord> laps) {
    final fuelMap = strategy?.fuelMap ?? 1;
    final measured = PracticeFuelCalculator.averagePercentPerLap(laps);
    return TestPlan.fromBriefing(
      briefing,
      startCompound: strategy?.startingTireCompound,
      fuelPerLapPercent: measured == null ? strategy?.assumedPercentPerLap : measured * PitStopCalculator.fuelMapFactor(fuelMap),
      fuelMap: fuelMap,
      fuelMapToTest: strategy?.fuelMapToTest ?? fuelMapTested(laps),
      raceStops: strategy?.pitStops,
    );
  }

  static int? fuelMapTested(List<PracticeLapRecord> laps) =>
      laps.where((l) => l.testNumber != null && (l.fuelMap ?? 1) > 1).map((l) => l.fuelMap!).firstOrNull;

  /// Dry compounds, softest first.
  static const List<String> _drySoftestFirst = ['Racing Soft', 'Racing Medium', 'Racing Hard'];

  final List<PlannedTestStint> stints;

  const TestPlan(this.stints);

  /// Builds the plan for a round. The long stints run hardest tyre
  /// first, then the rest softest first -- a fixed order, so a test
  /// already done keeps its number when the strategy changes its start
  /// tyre. [startCompound] (the saved strategy's starting tyre) is what
  /// the full race test starts on.
  ///
  /// [fuelPerLapPercent] (the strategy's figure, measured once practice
  /// has laps) sizes the stints to what a race stint can be: a long
  /// stint is one tank -- or the race distance, if a tank outlasts it --
  /// as testing the tyres past where a stint has to end anyway tells the
  /// strategy nothing (the wear rate over the tank says whether a set
  /// could do a second one). The low-fuel run gets enough fuel for its
  /// laps.
  ///
  /// [raceStops]: the strategy's stops -- the full race test runs to
  /// them, each stint on its map (see [PlannedTestStint.raceStops]).
  ///
  /// [fuelMap]: the strategy's map -- the full race test runs on it, the
  /// rest on Map 1 -- and [fuelPerLapPercent] is the use on it (scaled
  /// back to Map 1 to size the other stints). [fuelMapToTest]: a leaner map
  /// that might save a stop (RaceStrategy.fuelMapToTest) gets a short
  /// full-tank stint on the first long stint's tyre, to compare with it.
  factory TestPlan.fromBriefing(
    RaceBriefing briefing, {
    String? startCompound,
    double? fuelPerLapPercent,
    int fuelMap = 1,
    int? fuelMapToTest,
    List<PlannedPitStop>? raceStops,
  }) {
    // Map 1's use: what the long and low-fuel stints are run on.
    final perLap = fuelPerLapPercent != null && fuelPerLapPercent > 0
        ? fuelPerLapPercent / PitStopCalculator.fuelMapFactor(fuelMap)
        : null;
    final tankLaps = perLap == null ? null : ((longStintStartFuelPercent - reserveLaps * perLap) / perLap).floor().clamp(1, 999);
    final raceLaps = briefing.totalLaps > 0 ? briefing.totalLaps : null;
    final longLaps = tankLaps == null ? null : (raceLaps != null && raceLaps < tankLaps ? raceLaps : tankLaps);
    final longIsRace = longLaps != null && longLaps != tankLaps;
    // The low-fuel run: up to 4 laps, but no more than half a tank, on
    // just enough fuel for them (in 5s).
    final lowLaps = tankLaps == null ? lowFuelLaps : (tankLaps ~/ 2).clamp(1, lowFuelLaps);
    final lowFuel = perLap == null
        ? lowFuelStartPercent
        : ((((lowLaps + 1) * perLap) / 5).ceil() * 5).clamp(lowFuelStartPercent, longStintStartFuelPercent).toDouble();

    var compounds = [
      for (final c in _drySoftestFirst)
        if (briefing.availableTireCompounds.contains(c)) c,
    ];
    if (compounds.isEmpty) compounds = List.of(briefing.availableTireCompounds);
    if (compounds.isEmpty) return const TestPlan([]);

    final first = compounds.last; // the hardest
    final ordered = [first, ...compounds.where((c) => c != first)];

    final wet = wetStints(briefing.weather, slick: _slickFor(briefing, compounds));
    // Last: the whole race, to the strategy.
    final race = PlannedTestStint(
      number: 0,
      kind: TestStintKind.race,
      // The strategy's start tyre; before one is generated, the tyre it
      // would start on.
      compound: startCompound ?? PitStopCalculator.calculate(briefing).startingTireCompound,
      startFuelPercent: briefing.startingFuelPercent,
      laps: briefing.totalLaps,
      raceStops: raceStops,
    );
    if (wet.isNotEmpty && !_mostlyDry(briefing)) {
      return TestPlan([for (final (i, s) in [...wet, race].indexed) s.renumbered(i + 1, fuelMap: fuelMap)]);
    }

    final stints = <PlannedTestStint>[
      for (final (i, compound) in ordered.indexed)
        PlannedTestStint(
          number: i + 1,
          kind: TestStintKind.long,
          compound: compound,
          startFuelPercent: longStintStartFuelPercent,
          stopAtWearRemainingPercent: wearTargetRemainingPercent,
          laps: longLaps,
          lapsAreRaceDistance: longIsRace,
        ),
      if (fuelMapToTest != null && fuelMapToTest > 1)
        PlannedTestStint(
          number: 0,
          kind: TestStintKind.fuelMap,
          compound: first,
          startFuelPercent: longStintStartFuelPercent,
          laps: fuelMapTestLaps,
          fuelMap: fuelMapToTest,
        ),
      PlannedTestStint(
        number: ordered.length + 1,
        kind: TestStintKind.lowFuel,
        compound: compounds.first, // softest allowed
        startFuelPercent: lowFuel,
        laps: lowLaps,
      ),
    ];
    return TestPlan([
      for (final (i, s) in [...stints, ...wet, race].indexed) s.renumbered(i + 1, fuelMap: fuelMap),
    ]);
  }

  /// The wet-pace pairs for [forecast] (numbered from 1; empty for a dry
  /// forecast). Each pair is the two tyres a weather could call for, a
  /// few laps each at the same fuel:
  ///  - Wets vs Inters at the heaviest rain in the brief (R04+): the
  ///    start or finish tyre in the worst of it;
  ///  - Wets vs Inters again at the heaviest Inters rain (R04-R05), if
  ///    the heaviest needs Wets: whether Wets still pay as it eases, so
  ///    whether to run them on or switch;
  ///  - Inters vs [slick] at the lightest rain that needs Inters (R03):
  ///    where slicks take over, for the slick call.
  /// Ordered so a tyre carries over between pairs where it can.
  static List<PlannedTestStint> wetStints(WeatherForecast? forecast, {String slick = 'Racing Hard'}) {
    if (forecast == null) return const [];
    final rain = {for (final s in forecast.slots) if (s.isRain && s.tyre != WeatherTyre.slicks) s.number};
    if (rain.isEmpty) return const [];
    final heaviest = rain.reduce((a, b) => a > b ? a : b);
    final intersRain = rain.where((n) => n >= 4 && n <= 5);
    final pairs = <(int, String, String)>[
      if (heaviest >= 4) (heaviest, 'Heavy Wet', 'Intermediate'),
      if (heaviest >= 6 && intersRain.isNotEmpty) (intersRain.reduce((a, b) => a > b ? a : b), 'Intermediate', 'Heavy Wet'),
      if (rain.contains(3)) (3, 'Intermediate', slick),
    ];
    final stints = <PlannedTestStint>[];
    for (final (preset, first, second) in pairs) {
      // Start the pair on the tyre already fitted, if it's in it.
      final carried = stints.isNotEmpty && stints.last.compound == second;
      for (final (compound, other) in carried ? [(second, first), (first, second)] : [(first, second), (second, first)]) {
        stints.add(
          PlannedTestStint(
            number: stints.length + 1,
            kind: TestStintKind.wet,
            compound: compound,
            startFuelPercent: wetStartFuelPercent,
            laps: wetLaps,
            weather: 'R${preset.toString().padLeft(2, '0')}',
            comparedWith: other,
          ),
        );
      }
    }
    return stints;
  }

  /// The slick for the wet pairs: the hardest allowed (what a slick
  /// stint between showers is usually run on).
  static String _slickFor(RaceBriefing briefing, List<String> dry) {
    for (final c in _drySoftestFirst.reversed) {
      if (dry.contains(c)) return c;
    }
    return 'Racing Hard';
  }

  /// The brief's dry running is over half the race, so tyre life on
  /// slicks still matters.
  static bool _mostlyDry(RaceBriefing briefing) {
    final forecast = briefing.weather;
    if (forecast == null || briefing.totalLaps <= 0) return false;
    var dryLaps = 0;
    for (final phase in forecast.phases.where((p) => p.tyre == WeatherTyre.slicks)) {
      final (from, to) = forecast.lapsOfPhase(phase, briefing.totalLaps);
      dryLaps += to - from + 1;
    }
    return dryLaps > briefing.totalLaps / 2;
  }

}
