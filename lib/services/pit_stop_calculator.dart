import '../models/race_briefing.dart';
import '../models/race_strategy.dart';

/// Deterministically computes a pit-stop plan from a RaceBriefing --
/// pure arithmetic, no AI involved, so the SAME briefing always
/// produces the EXACT SAME strategy (same pit laps, same tire picks).
///
/// This exists because letting an LLM freely invent the fuel-burn
/// assumption and pit-lap math from scratch on every call produced a
/// different "guess" each time (no fixed seed/temperature, and LLMs
/// are inherently inconsistent at multi-step arithmetic) -- the actual
/// numbers the driver needs to trust are now computed here instead;
/// RaceStrategistService only asks the AI to phrase the explanation of
/// an already-fixed plan, not to invent the plan itself.
class PitStopCalculator {
  /// Baseline fuel consumption for a Gr.3 car at a 1x fuel consumption
  /// multiplier, as a percent of the tank burned per lap on a
  /// medium-length circuit (~4-5km). This is a deliberately simple,
  /// fixed prior -- used only when no real measured practice-session
  /// consumption is available yet (see measuredPercentPerLap/
  /// ShiftAwareFuelCalculator), so it only needs to be a reasonable,
  /// CONSISTENT starting point, not a perfect one.
  static const double _basePercentPerLapAt1x = 2.5;

  /// Reference track length (meters) the base consumption figure above
  /// assumes -- longer tracks burn more fuel per lap in absolute terms
  /// even at the same consumption rate, so this scales the base figure
  /// by how the given track's length compares to this reference.
  static const double _referenceTrackLengthMeters = 4500.0;

  /// Dry tire compounds in hardness order, hardest (longest-lasting,
  /// least grip) first -- used to pick a sensible default starting
  /// compound and stint assignment when the briefing doesn't mandate
  /// a specific one.
  static const List<String> _dryHardnessOrder = ['Racing Hard', 'Racing Medium', 'Racing Soft'];

  /// Default BASE pit-stop time loss assumption (seconds) -- pit lane
  /// entry + stationary refuel time + exit, EXCLUDING the tyre change
  /// itself -- used only when the driver hasn't measured a real value
  /// yet (see measuredPitStopTimeLossSeconds). A generic mid-pack
  /// GT3/Gr.3 pit-lane loss on a typical circuit.
  static const double _defaultPitStopTimeLossSeconds = 22.0;

  /// Fixed average tyre-change time loss (seconds), added on top of
  /// the base pit-stop loss for every stop that fits a compound
  /// (i.e. every stop PitStopCalculator schedules, since every
  /// scheduled stop fits tyres as well as fuel) -- mirrors standard
  /// sim-racing pit-calculators splitting "base pit loss" from
  /// "tyre-change loss" as two separate inputs. Not configurable (per
  /// the user's own measured average across GT3/Gr.3 pit stops).
  static const double _tyreChangeLossSeconds = 3.5;

  /// Computes the full deterministic strategy for a given briefing.
  /// trackLengthMeters is optional (from TrackDatabase, if the
  /// selected track matched a known entry) -- falls back to the
  /// reference length (no scaling adjustment) if unavailable.
  ///
  /// measuredPercentPerLap, when provided, is REAL fuel consumption
  /// averaged from the driver's own logged practice laps (see
  /// PracticeLapLogger/PracticeLapRecord.fuelConsumedPercent) --
  /// replacing the generic baseline-times-multiplier guess entirely,
  /// since actual measured data is strictly better than a prior once
  /// it exists. Still fully deterministic: the same practice log
  /// always produces the same average, so this doesn't reintroduce
  /// the "different plan every time" problem.
  ///
  /// measuredPitStopTimeLossSeconds, when provided, is the driver's own
  /// measured in-lap+stationary+out-lap time loss (see
  /// PitStopTimeRecord) -- used to compute totalEstimatedTimeLossSeconds
  /// on the returned RaceStrategy so the driver can see the real total
  /// cost of their stop count, not just an assumed number.
  static RaceStrategy calculate(
    RaceBriefing briefing, {
    double? trackLengthMeters,
    double? measuredPercentPerLap,
    double? measuredPitStopTimeLossSeconds,
  }) {
    // When the driver has measured a real total stop time (in-lap +
    // stationary + out-lap vs. a normal lap), that figure ALREADY
    // includes the tyre change -- it's the whole stop, start to
    // finish -- so the fixed tyre-change constant is only added on top
    // of the DEFAULT (unmeasured) base pit-lane loss, never double
    // counted alongside a real measurement.
    final pitStopTimeLossSeconds = (measuredPitStopTimeLossSeconds != null && measuredPitStopTimeLossSeconds > 0)
        ? measuredPitStopTimeLossSeconds
        : _defaultPitStopTimeLossSeconds + _tyreChangeLossSeconds;
    final double assumedPercentPerLap;
    if (measuredPercentPerLap != null && measuredPercentPerLap > 0) {
      assumedPercentPerLap = measuredPercentPerLap;
    } else {
      final lengthScale = (trackLengthMeters ?? _referenceTrackLengthMeters) / _referenceTrackLengthMeters;
      assumedPercentPerLap = _basePercentPerLapAt1x * briefing.fuelConsumptionMultiplier * lengthScale;
    }

    // Usable fuel excludes the finish reserve (a safety margin the
    // driver wants left in the tank at the FINISH, not burned down to
    // the theoretical empty point) -- mirrors standard sim-racing
    // pit-calculator practice, since real consumption running even
    // slightly worse than measured would otherwise risk running dry a
    // lap early. Clamped to never go negative/zero even if the
    // reserve is misconfigured larger than the starting fuel itself.
    final usableFuelPercent =
        (briefing.startingFuelPercent - briefing.finishFuelReservePercent).clamp(assumedPercentPerLap, briefing.startingFuelPercent);

    final fuelRangeLaps = (usableFuelPercent / assumedPercentPerLap).floor().clamp(1, briefing.totalLaps);

    // Stint length is the SHORTER of the fuel-range and the maximum
    // tyre stint cap (0 = no cap, i.e. fuel-range-only as before) --
    // mirrors standard sim-racing pit-calculator practice: tyre grip
    // can fall off a cliff well before the tank runs dry.
    final lapsPerTank = briefing.maxTyreStintLaps > 0
        ? (fuelRangeLaps < briefing.maxTyreStintLaps ? fuelRangeLaps : briefing.maxTyreStintLaps)
        : fuelRangeLaps;

    // Fuel-only stop count: how many refuels are needed to cover the
    // full race distance at a constant lapsPerTank stint length.
    final fuelStopsNeeded = (briefing.totalLaps / lapsPerTank).ceil() - 1;
    // Whichever is larger -- the regulations' mandatory minimum, or
    // what fuel capacity/tyre life actually requires -- but never more
    // stops than there are laps to split them across.
    final finalStopCount = fuelStopsNeeded.clamp(briefing.mandatoryPitStopCount, briefing.totalLaps - 1);

    // Assign a (potentially different) compound per stint -- harder
    // compounds to the longer/earlier stints where durability matters
    // most, softer compounds to shorter stints where outright pace
    // matters more, cycling through every compound the driver actually
    // selected rather than only ever using one for the whole race.
    final stintCount = finalStopCount + 1;
    final compoundsForStints = _assignCompoundsToStints(briefing, stintCount);
    final startingTire = compoundsForStints.first;

    final pitStops = <PlannedPitStop>[];
    if (finalStopCount > 0) {
      // Evenly space stops across the race distance (rather than
      // strictly every lapsPerTank laps) so a mandatory-stop-count
      // override doesn't cluster stops unrealistically close together.
      for (var i = 1; i <= finalStopCount; i++) {
        final lap = ((briefing.totalLaps * i) / (finalStopCount + 1)).round().clamp(1, briefing.totalLaps - 1);
        final compound = compoundsForStints[i];
        final isMandatory = compound == briefing.mandatoryTyreCompound;
        pitStops.add(PlannedPitStop(
          lap: lap,
          tireCompound: compound,
          reasoning: 'Scheduled refuel and tire change to $compound'
              '${isMandatory ? ' (mandatory compound)' : ''} at the computed fuel/tire window.',
        ));
      }
    }

    final constraintNote = briefing.maxTyreStintLaps > 0 && lapsPerTank == briefing.maxTyreStintLaps && lapsPerTank < fuelRangeLaps
        ? ' Stint length is capped by the ${briefing.maxTyreStintLaps}-lap tyre limit, not fuel range.'
        : '';
    final reserveNote = briefing.finishFuelReservePercent > 0
        ? ' Keeps a ${briefing.finishFuelReservePercent.toStringAsFixed(0)}% fuel reserve at the finish.'
        : '';

    final summary = finalStopCount == 0
        ? 'No pit stops needed -- starting fuel and $startingTire tires last the full ${briefing.totalLaps}-lap race.$reserveNote'
        : '$finalStopCount-stop strategy starting on $startingTire, pitting at '
            '${pitStops.map((p) => 'lap ${p.lap} (${p.tireCompound})').join(', ')} to refuel'
            '${briefing.mandatoryTyreCompound != 'N/A' ? ' and fit the mandatory ${briefing.mandatoryTyreCompound} tire' : ''}.'
            '$constraintNote$reserveNote';

    return RaceStrategy(
      pitStops: pitStops,
      startingTireCompound: startingTire,
      summary: summary,
      assumedPercentPerLap: assumedPercentPerLap,
      totalEstimatedTimeLossSeconds: pitStops.length * pitStopTimeLossSeconds,
      pitStopTimeIsMeasured: measuredPitStopTimeLossSeconds != null && measuredPitStopTimeLossSeconds > 0,
    );
  }

  /// Returns one compound per stint (length == stintCount), using every
  /// compound the driver actually selected (not just the hardest one)
  /// when there are enough stints to use them. Hardest-available first
  /// (durability for the opening/longest stints), progressing toward
  /// softer compounds in later stints, and cycling back to the hardest
  /// again if there are more stints than compounds selected. If
  /// mandatoryTyreCompound is set, it's forced into the LAST stint
  /// (the stint that must still be running at the finish, per GT7's
  /// mandatory-compound rule -- the driver must use it at some point).
  static List<String> _assignCompoundsToStints(RaceBriefing briefing, int stintCount) {
    final selectedDry = [
      for (final compound in _dryHardnessOrder)
        if (briefing.availableTireCompounds.contains(compound)) compound,
    ];

    final pool = selectedDry.isNotEmpty
        ? selectedDry
        : (briefing.availableTireCompounds.isNotEmpty ? briefing.availableTireCompounds : const ['Racing Medium']);

    final stints = List<String>.generate(stintCount, (i) => pool[i % pool.length]);

    if (briefing.mandatoryTyreCompound != 'N/A' &&
        briefing.availableTireCompounds.contains(briefing.mandatoryTyreCompound)) {
      stints[stints.length - 1] = briefing.mandatoryTyreCompound;
    }

    return stints;
  }
}
