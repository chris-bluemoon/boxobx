import 'race_briefing.dart';

enum TestStintKind {
  /// Full tank, run the tyres down to the wear target -- tyre life,
  /// pace drop-off, fuel per lap.
  long,

  /// Light fuel, a few laps on fresh tyres -- how much faster the car is
  /// light, compared with the same compound's full-tank stint.
  lowFuel,
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

  /// Low-fuel stints: how many laps to run.
  final int? laps;

  const PlannedTestStint({
    required this.number,
    required this.kind,
    required this.compound,
    required this.startFuelPercent,
    this.stopAtWearRemainingPercent,
    this.laps,
  });

  /// Short name for the compound ("Soft", "Medium"...).
  String get compoundShort => compound.replaceFirst('Racing ', '');

  /// e.g. "Soft · 100% fuel · until 70% worn" / "Soft · 20% fuel · 4 laps".
  String get target {
    final fuel = '${startFuelPercent.toStringAsFixed(0)}% fuel';
    return switch (kind) {
      TestStintKind.long =>
        '$compoundShort · $fuel · until ${(100 - stopAtWearRemainingPercent!).toStringAsFixed(0)}% worn',
      TestStintKind.lowFuel => '$compoundShort · $fuel · $laps laps',
    };
  }

  /// What this stint tells us, for the plan screen.
  String get purpose => switch (kind) {
    TestStintKind.long => 'Tyre life and drop-off, fuel per lap',
    TestStintKind.lowFuel => 'Fuel-weight effect (light vs full-tank pace)',
  };
}

/// The stints to run in practice for a round, so the strategy has
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
    return TestPlan(stints);
  }

}
