// Standalone validation for PitStopCalculator: the deterministic
// pit-stop math that replaced letting the AI freely invent pit laps
// and fuel assumptions from scratch (which produced a different
// "guess" on every call with the same briefing).
//
// Run with: dart run test_scripts/pit_stop_calculator_test.dart
import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/services/pit_stop_calculator.dart';

void check(String label, bool condition) {
  print('${condition ? "PASS" : "FAIL"} $label');
  if (!condition) throw Exception('Failed: $label');
}

void main() {
  final briefing = RaceBriefing(
    trackName: 'Suzuka Circuit',
    totalLaps: 32,
    fuelConsumptionMultiplier: 3.0,
    startingFuelPercent: 100,
    availableTireCompounds: const ['Racing Hard'],
    mandatoryPitStopCount: 1,
  );

  // --- Determinism: same briefing -> byte-identical result ---
  final a = PitStopCalculator.calculate(briefing);
  final b = PitStopCalculator.calculate(briefing);
  check('pit laps identical across repeated calls', a.pitStops.map((p) => p.lap).toList().toString() == b.pitStops.map((p) => p.lap).toList().toString());
  check('tire compounds identical across repeated calls', a.pitStops.map((p) => p.tireCompound).toList().toString() == b.pitStops.map((p) => p.tireCompound).toList().toString());
  check('assumed fuel-per-lap identical across repeated calls', a.assumedPercentPerLap == b.assumedPercentPerLap);
  check('starting tire identical across repeated calls', a.startingTireCompound == b.startingTireCompound);

  // --- Mandatory pit stop count is always respected ---
  check('at least mandatoryPitStopCount stops are scheduled', a.pitStops.length >= briefing.mandatoryPitStopCount);

  // --- No fuel multiplier -> fewer/no stops needed than a high multiplier ---
  final lowFuelBriefing = RaceBriefing(
    trackName: 'Suzuka Circuit',
    totalLaps: 32,
    fuelConsumptionMultiplier: 1.0,
    startingFuelPercent: 100,
    availableTireCompounds: const ['Racing Hard'],
  );
  final lowFuelStrategy = PitStopCalculator.calculate(lowFuelBriefing);
  check(
    'a lower fuel consumption multiplier never needs MORE stops than a higher one',
    lowFuelStrategy.pitStops.length <= a.pitStops.length,
  );

  // --- Mandatory tyre compound is honored in at least one stop ---
  final mandatoryTyreBriefing = RaceBriefing(
    trackName: 'Suzuka Circuit',
    totalLaps: 32,
    fuelConsumptionMultiplier: 3.0,
    startingFuelPercent: 100,
    availableTireCompounds: const ['Racing Hard', 'Racing Medium'],
    mandatoryTyreCompound: 'Racing Medium',
    mandatoryPitStopCount: 1,
  );
  final mandatoryTyreStrategy = PitStopCalculator.calculate(mandatoryTyreBriefing);
  check(
    'mandatory tyre compound appears in the starting tire or a pit stop',
    mandatoryTyreStrategy.startingTireCompound == 'Racing Medium' ||
        mandatoryTyreStrategy.pitStops.any((p) => p.tireCompound == 'Racing Medium'),
  );

  // --- No pit stops needed when fuel/laps comfortably allow it ---
  final noStopBriefing = RaceBriefing(
    trackName: 'Short Sprint',
    totalLaps: 5,
    fuelConsumptionMultiplier: 1.0,
    startingFuelPercent: 100,
    availableTireCompounds: const ['Racing Soft'],
  );
  final noStopStrategy = PitStopCalculator.calculate(noStopBriefing);
  check('a short low-fuel-use race needs no pit stops', noStopStrategy.pitStops.isEmpty);
  check('summary mentions no stops are needed', noStopStrategy.summary.toLowerCase().contains('no pit stop'));

  // --- Track length scaling: a much longer track burns more fuel/lap ---
  final longTrackStrategy = PitStopCalculator.calculate(briefing, trackLengthMeters: 13000);
  final shortTrackStrategy = PitStopCalculator.calculate(briefing, trackLengthMeters: 2000);
  check(
    'a longer track has a higher assumed fuel-per-lap than a shorter one',
    longTrackStrategy.assumedPercentPerLap > shortTrackStrategy.assumedPercentPerLap,
  );

  // --- Regression: selecting Hard+Medium+Soft with enough stints to
  // need all three must actually use Soft somewhere, not silently
  // ignore it in favor of always picking the hardest compound. ---
  final allThreeCompoundsBriefing = RaceBriefing(
    trackName: 'Suzuka Circuit',
    totalLaps: 32,
    fuelConsumptionMultiplier: 6.0, // high enough to force multiple stops
    startingFuelPercent: 100,
    availableTireCompounds: const ['Racing Hard', 'Racing Medium', 'Racing Soft'],
  );
  final allThreeStrategy = PitStopCalculator.calculate(allThreeCompoundsBriefing);
  final usedCompounds = {
    allThreeStrategy.startingTireCompound,
    ...allThreeStrategy.pitStops.map((p) => p.tireCompound),
  };
  check(
    'enough stints are scheduled to need more than one compound (test setup sanity check)',
    allThreeStrategy.pitStops.length >= 2,
  );
  check(
    'Racing Soft is actually used somewhere in the strategy when selected and enough stints exist',
    usedCompounds.contains('Racing Soft'),
  );
  check(
    'Racing Medium is actually used somewhere in the strategy when selected and enough stints exist',
    usedCompounds.contains('Racing Medium'),
  );
  check(
    'Racing Hard is actually used somewhere in the strategy when selected and enough stints exist',
    usedCompounds.contains('Racing Hard'),
  );

  // --- With only 1 stint (no stops needed), only one compound is used
  // -- Soft is a perfectly valid single choice, not "ignored". ---
  final singleStintBriefing = RaceBriefing(
    trackName: 'Short Sprint',
    totalLaps: 5,
    fuelConsumptionMultiplier: 1.0,
    startingFuelPercent: 100,
    availableTireCompounds: const ['Racing Hard', 'Racing Medium', 'Racing Soft'],
  );
  final singleStintStrategy = PitStopCalculator.calculate(singleStintBriefing);
  check(
    'with only one stint, the hardest selected compound is used for durability (expected, not a bug)',
    singleStintStrategy.startingTireCompound == 'Racing Hard',
  );

  // --- measuredPercentPerLap (real practice-lap data) overrides the
  // generic baseline assumption entirely when provided. ---
  final measuredStrategy = PitStopCalculator.calculate(briefing, measuredPercentPerLap: 9.5);
  check(
    'a provided measuredPercentPerLap is used instead of the generic baseline',
    measuredStrategy.assumedPercentPerLap == 9.5,
  );

  final measuredStrategyAgain = PitStopCalculator.calculate(briefing, measuredPercentPerLap: 9.5);
  check(
    'the same measuredPercentPerLap still produces a deterministic (identical) result',
    measuredStrategy.pitStops.map((p) => p.lap).toString() ==
        measuredStrategyAgain.pitStops.map((p) => p.lap).toString(),
  );

  // --- A non-positive measuredPercentPerLap is ignored (falls back to
  // the generic baseline) rather than producing nonsensical math. ---
  final ignoredBadMeasurement = PitStopCalculator.calculate(briefing, measuredPercentPerLap: 0.0);
  check(
    'a non-positive measuredPercentPerLap falls back to the generic baseline instead of being used as-is',
    ignoredBadMeasurement.assumedPercentPerLap == a.assumedPercentPerLap,
  );

  // --- Pit stop time loss: without a measurement, uses the generic
  // default and flags pitStopTimeIsMeasured == false. ---
  check(
    'without a measured pit-stop time, pitStopTimeIsMeasured is false',
    !a.pitStopTimeIsMeasured,
  );
  check(
    'totalEstimatedTimeLossSeconds scales with the number of stops (default base 22.0s + fixed 3.5s tyre change = 25.5s/stop)',
    a.totalEstimatedTimeLossSeconds == a.pitStops.length * 25.5,
  );

  // --- Providing a measured pit-stop time overrides the default and
  // is reflected in the total. ---
  final measuredPitTimeStrategy = PitStopCalculator.calculate(
    briefing,
    measuredPitStopTimeLossSeconds: 19.5,
  );
  check(
    'a provided measuredPitStopTimeLossSeconds sets pitStopTimeIsMeasured to true',
    measuredPitTimeStrategy.pitStopTimeIsMeasured,
  );
  check(
    'totalEstimatedTimeLossSeconds uses the measured per-stop time, not the default',
    measuredPitTimeStrategy.totalEstimatedTimeLossSeconds ==
        measuredPitTimeStrategy.pitStops.length * 19.5,
  );

  // --- A non-positive measured pit-stop time falls back to the default,
  // same pattern as measuredPercentPerLap. ---
  final ignoredBadPitTime = PitStopCalculator.calculate(briefing, measuredPitStopTimeLossSeconds: 0.0);
  check(
    'a non-positive measuredPitStopTimeLossSeconds falls back to the default and is NOT flagged as measured',
    !ignoredBadPitTime.pitStopTimeIsMeasured &&
        ignoredBadPitTime.totalEstimatedTimeLossSeconds == a.totalEstimatedTimeLossSeconds,
  );

  // --- A race with zero pit stops has zero total time loss regardless
  // of what pit-stop time was measured/assumed. ---
  check(
    'a strategy with no pit stops has zero total estimated time loss',
    noStopStrategy.totalEstimatedTimeLossSeconds == 0.0,
  );

  // --- Tyre-change loss: the fixed 3.5s is added on top of the
  // default base pit loss (22.0s), but NOT added on top of a measured
  // total (which already includes the real tyre-change time). ---
  check(
    'default pit-stop time loss includes the 22.0s base plus the fixed 3.5s tyre change',
    !a.pitStopTimeIsMeasured && (a.totalEstimatedTimeLossSeconds / a.pitStops.length) == 25.5,
  );
  check(
    'a measured total time loss is used as-is, without double-adding the tyre-change constant',
    (measuredPitTimeStrategy.totalEstimatedTimeLossSeconds / measuredPitTimeStrategy.pitStops.length) == 19.5,
  );

  // --- Finish fuel reserve: a larger reserve leaves less usable fuel,
  // so it should never need FEWER stops than with zero reserve. ---
  final noReserveBriefing = RaceBriefing(
    trackName: 'Suzuka Circuit',
    totalLaps: 32,
    fuelConsumptionMultiplier: 3.0,
    startingFuelPercent: 100,
    availableTireCompounds: const ['Racing Hard'],
  );
  final withReserveBriefing = RaceBriefing(
    trackName: 'Suzuka Circuit',
    totalLaps: 32,
    fuelConsumptionMultiplier: 3.0,
    startingFuelPercent: 100,
    finishFuelReservePercent: 20.0,
    availableTireCompounds: const ['Racing Hard'],
  );
  final noReserveStrategy = PitStopCalculator.calculate(noReserveBriefing);
  final withReserveStrategy = PitStopCalculator.calculate(withReserveBriefing);
  check(
    'a finish fuel reserve never results in FEWER stops than no reserve',
    withReserveStrategy.pitStops.length >= noReserveStrategy.pitStops.length,
  );
  check(
    'a finish fuel reserve is mentioned in the summary',
    withReserveStrategy.summary.contains('reserve'),
  );

  // --- Max tyre stint cap: a short cap forces MORE (or equal) stops
  // than fuel range alone would require. ---
  final noTyreCapBriefing = RaceBriefing(
    trackName: 'Suzuka Circuit',
    totalLaps: 32,
    fuelConsumptionMultiplier: 1.0,
    startingFuelPercent: 100,
    availableTireCompounds: const ['Racing Hard'],
  );
  final tightTyreCapBriefing = RaceBriefing(
    trackName: 'Suzuka Circuit',
    totalLaps: 32,
    fuelConsumptionMultiplier: 1.0,
    startingFuelPercent: 100,
    maxTyreStintLaps: 8,
    availableTireCompounds: const ['Racing Hard'],
  );
  final noTyreCapStrategy = PitStopCalculator.calculate(noTyreCapBriefing);
  final tightTyreCapStrategy = PitStopCalculator.calculate(tightTyreCapBriefing);
  check(
    'a tight tyre stint cap forces at least as many stops as fuel range alone',
    tightTyreCapStrategy.pitStops.length >= noTyreCapStrategy.pitStops.length,
  );
  check(
    'a tight tyre stint cap actually increases the stop count when fuel range alone would need fewer',
    tightTyreCapStrategy.pitStops.length > noTyreCapStrategy.pitStops.length,
  );
  check(
    'a tyre stint cap that is the binding constraint is mentioned in the summary',
    tightTyreCapStrategy.summary.contains('tyre limit'),
  );

  // --- maxTyreStintLaps of 0 disables the cap (identical to omitting it). ---
  final explicitZeroCapStrategy = PitStopCalculator.calculate(
    RaceBriefing(
      trackName: 'Suzuka Circuit',
      totalLaps: 32,
      fuelConsumptionMultiplier: 1.0,
      startingFuelPercent: 100,
      maxTyreStintLaps: 0,
      availableTireCompounds: const ['Racing Hard'],
    ),
  );
  check(
    'maxTyreStintLaps of 0 behaves identically to no cap at all',
    explicitZeroCapStrategy.pitStops.length == noTyreCapStrategy.pitStops.length,
  );

  print('\nAll PitStopCalculator checks passed.');
}
