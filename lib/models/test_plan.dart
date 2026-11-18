import 'race_briefing.dart';
import 'weather_forecast.dart';
import '../services/pit_stop_calculator.dart';

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

  /// Low-fuel and wet stints: how many laps to run.
  final int? laps;

  /// Wet stints: the GT7 rain preset to set in the lobby ("R06"); the
  /// stint's laps are tagged with it. Null = dry.
  final String? weather;

  /// Wet stints: the tyre it's compared against in the same weather.
  final String? comparedWith;

  const PlannedTestStint({
    required this.number,
    required this.kind,
    required this.compound,
    required this.startFuelPercent,
    this.stopAtWearRemainingPercent,
    this.laps,
    this.weather,
    this.comparedWith,
  });

  PlannedTestStint renumbered(int n) => PlannedTestStint(
    number: n,
    kind: kind,
    compound: compound,
    startFuelPercent: startFuelPercent,
    stopAtWearRemainingPercent: stopAtWearRemainingPercent,
    laps: laps,
    weather: weather,
    comparedWith: comparedWith,
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

  /// e.g. "Soft · 100% fuel · until 70% worn" / "Soft · 20% fuel · 4 laps".
  String get target {
    final fuel = '${startFuelPercent.toStringAsFixed(0)}% fuel';
    return switch (kind) {
      TestStintKind.long =>
        '$compoundShort · $fuel · until ${(100 - stopAtWearRemainingPercent!).toStringAsFixed(0)}% worn',
      TestStintKind.lowFuel => '$compoundShort · $fuel · $laps laps',
      TestStintKind.wet => '$compoundShort · $weather rain · $fuel · $laps laps',
      TestStintKind.race => 'Full race · $laps laps · start on $compoundShort · $fuel · change tyres when the track calls for it',
    };
  }

  /// What this stint tells us, for the plan screen.
  String get purpose => switch (kind) {
    TestStintKind.long => 'Tyre life and drop-off, fuel per lap',
    TestStintKind.lowFuel => 'Fuel-weight effect (light vs full-tank pace)',
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
/// until the tyres are 70% worn (GT7 grip tends to fall away somewhere
/// below half remaining, so this captures the drop-off without wasting
/// laps on dead tyres) -- then a short low-fuel run on the softest
/// compound for the fuel-weight effect.
class TestPlan {
  static const double longStintStartFuelPercent = 100;
  static const double wearTargetRemainingPercent = 30;
  static const double lowFuelStartPercent = 20;
  static const int lowFuelLaps = 4;
  static const int wetLaps = 4;
  static const double wetStartFuelPercent = 100;


  /// Dry compounds, softest first.
  static const List<String> _drySoftestFirst = ['Racing Soft', 'Racing Medium', 'Racing Hard'];

  final List<PlannedTestStint> stints;

  const TestPlan(this.stints);

  /// Builds the plan for a round. [startCompound] (e.g. the saved
  /// strategy's starting tyre) goes first, mirroring the race start;
  /// otherwise Medium if allowed. The rest follow softest first.
  factory TestPlan.fromBriefing(RaceBriefing briefing, {String? startCompound}) {
    var compounds = [
      for (final c in _drySoftestFirst)
        if (briefing.availableTireCompounds.contains(c)) c,
    ];
    if (compounds.isEmpty) compounds = List.of(briefing.availableTireCompounds);
    if (compounds.isEmpty) return const TestPlan([]);

    final first = compounds.contains(startCompound)
        ? startCompound!
        : compounds.contains('Racing Medium')
        ? 'Racing Medium'
        : compounds.first;
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
    );
    if (wet.isNotEmpty && !_mostlyDry(briefing)) {
      return TestPlan([for (final (i, s) in [...wet, race].indexed) s.renumbered(i + 1)]);
    }

    final stints = <PlannedTestStint>[
      for (final (i, compound) in ordered.indexed)
        PlannedTestStint(
          number: i + 1,
          kind: TestStintKind.long,
          compound: compound,
          startFuelPercent: longStintStartFuelPercent,
          stopAtWearRemainingPercent: wearTargetRemainingPercent,
        ),
      PlannedTestStint(
        number: ordered.length + 1,
        kind: TestStintKind.lowFuel,
        compound: compounds.first, // softest allowed
        startFuelPercent: lowFuelStartPercent,
        laps: lowFuelLaps,
      ),
    ];
    return TestPlan([
      for (final (i, s) in [...stints, ...wet, race].indexed) s.renumbered(i + 1),
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
