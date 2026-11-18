import '../models/race_briefing.dart';
import '../models/race_strategy.dart';
import '../models/weather_forecast.dart';
import 'base_rates.dart';
import 'wet_pace_table.dart';

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
  /// Baseline fuel use at a 1x fuel multiplier on Fuel Map 1: 1.7% of
  /// the tank a lap on a ~5 km lap (community figures for GT7: 1.6-1.8%
  /// on 4.5-5.5 km with a 100 L tank, scaling with the multiplier -- 2x
  /// 3.3-3.6%, 4x 6.6-7.2%, 6x 10-11%). Only used until the driver's own
  /// laps measure it (this round's, or earlier rounds' -- see BaseRates).
  static const double _basePercentPerLapAt1x = 1.7;

  /// The lap length [_basePercentPerLapAt1x] is for; a longer lap burns
  /// proportionally more.
  static const double _referenceTrackLengthMeters = 5000.0;

  /// GT7's fuel maps (MFD): 1 is full power, each map up burns less fuel
  /// and gives up a little pace. Assumed, not yet measured: about
  /// [fuelMapSavingPerStep] less fuel per map (community: Map 3 with
  /// short-shifting stretches a tank about 25-30%), costing about
  /// [fuelMapPaceCostPerKmPerStep] s per km of lap per map.
  static const int maxFuelMap = 6;
  static const double fuelMapSavingPerStep = 0.10;
  static const double fuelMapPaceCostPerKmPerStep = 0.05;

  /// Fuel use on [map] against Map 1.
  static double fuelMapFactor(int map) => 1 - fuelMapSavingPerStep * (map - 1);

  /// Seconds a lap given up on [map] against Map 1.
  static double fuelMapPaceCost(int map, double trackLengthMeters) =>
      fuelMapPaceCostPerKmPerStep * (map - 1) * trackLengthMeters / 1000;

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

  /// Fuel left in the tank at the finish, in laps' worth, when the brief
  /// doesn't set a reserve: half a lap, so running slightly heavier than
  /// the figure doesn't run dry on the last lap.
  static const double finishReserveLaps = 0.5;

  /// A set counts as worn out at this much tyre left (the HUD gauge):
  /// a tyre's life is the laps it takes to wear down to it.
  static const double wornOutPercent = 30;

  /// Laps a [wearPerLap] tyre lasts (see [wornOutPercent]).
  static int tyreLifeLaps(double wearPerLap) => wearPerLap <= 0 ? 999 : ((100 - wornOutPercent) / wearPerLap).floor();

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
  /// RaceBriefing.pitStopTimeSeconds) -- used to compute totalEstimatedTimeLossSeconds
  /// on the returned RaceStrategy so the driver can see the real total
  /// cost of their stop count, not just an assumed number.
  ///
  /// The plan is worked out on every fuel map (see [fuelMapFactor]) and
  /// the one losing the least time overall kept: the pit stops it costs
  /// plus the pace given up on every lap. Measured fuel use is taken to
  /// be on Map 1.
  static RaceStrategy calculate(
    RaceBriefing briefing, {
    double? trackLengthMeters,
    double? measuredPercentPerLap,
    double? measuredPitStopTimeLossSeconds,
    WetPaceTable? wetPace,
    BaseRates baseRates = BaseRates.none,
    int maxFuelMap = PitStopCalculator.maxFuelMap,
  }) {
    RaceStrategy at(int map) => _calculateOnMap(
      briefing,
      fuelMap: map,
      trackLengthMeters: trackLengthMeters,
      measuredPercentPerLap: measuredPercentPerLap,
      measuredPitStopTimeLossSeconds: measuredPitStopTimeLossSeconds,
      wetPace: wetPace,
      baseRates: baseRates,
    );
    final length = trackLengthMeters ?? _referenceTrackLengthMeters;
    double cost(RaceStrategy plan) =>
        plan.totalEstimatedTimeLossSeconds + briefing.totalLaps * fuelMapPaceCost(plan.fuelMap, length);

    final map1 = at(1);
    var best = map1;
    for (var map = 2; map <= maxFuelMap; map++) {
      final plan = at(map);
      if (cost(plan) < cost(best) - 0.5) best = plan;
    }
    if (best.fuelMap == 1) return map1;

    final saved = cost(map1) - cost(best);
    final pace = fuelMapPaceCost(best.fuelMap, length);
    final stopsSaved = map1.pitStops.length - best.pitStops.length;
    final line =
        'Fuel Map ${best.fuelMap}: about ${((1 - fuelMapFactor(best.fuelMap)) * 100).round()}% less fuel '
        '(${best.assumedPercentPerLap.toStringAsFixed(2)}%/lap) for about ${pace.toStringAsFixed(2)}s a lap -- '
        '${stopsSaved > 0 ? '$stopsSaved stop${stopsSaved == 1 ? '' : 's'} fewer than Map 1' : 'fewer laps short on fuel'}, '
        'about ${saved.toStringAsFixed(0)}s quicker over the race. The map figures are assumed -- '
        'test a stint on Map ${best.fuelMap} to measure them.';
    return best.copyWith(
      summary: 'Run Fuel Map ${best.fuelMap}. ${best.summary}',
      basis: [best.basis.first, line, ...best.basis.skip(1)],
    );
  }

  static RaceStrategy _calculateOnMap(
    RaceBriefing briefing, {
    required int fuelMap,
    double? trackLengthMeters,
    double? measuredPercentPerLap,
    double? measuredPitStopTimeLossSeconds,
    WetPaceTable? wetPace,
    BaseRates baseRates = BaseRates.none,
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
    final double map1PercentPerLap;
    final baseFuel = baseRates.fuel;
    final km = trackLengthMeters == null ? null : trackLengthMeters / 1000;
    if (measuredPercentPerLap != null && measuredPercentPerLap > 0) {
      map1PercentPerLap = measuredPercentPerLap;
    } else if (baseFuel != null && trackLengthMeters != null) {
      // Your laps in earlier rounds, scaled to this round's fuel setting
      // and lap length.
      map1PercentPerLap = baseFuel.perLap(briefing.fuelConsumptionMultiplier, trackLengthMeters);
    } else {
      final lengthScale = (trackLengthMeters ?? _referenceTrackLengthMeters) / _referenceTrackLengthMeters;
      map1PercentPerLap = _basePercentPerLapAt1x * briefing.fuelConsumptionMultiplier * lengthScale;
    }
    final assumedPercentPerLap = map1PercentPerLap * fuelMapFactor(fuelMap);

    // Usable fuel excludes the finish reserve (a safety margin the
    // driver wants left in the tank at the FINISH, not burned down to
    // the theoretical empty point) -- mirrors standard sim-racing
    // pit-calculator practice, since real consumption running even
    // slightly worse than measured would otherwise risk running dry a
    // lap early. Clamped to never go negative/zero even if the
    // reserve is misconfigured larger than the starting fuel itself.
    final reservePercent = briefing.finishFuelReservePercent > 0
        ? briefing.finishFuelReservePercent
        : finishReserveLaps * assumedPercentPerLap;
    final usableFuelPercent =
        (briefing.startingFuelPercent - reservePercent).clamp(assumedPercentPerLap, briefing.startingFuelPercent);

    final fuelRangeLaps = (usableFuelPercent / assumedPercentPerLap).floor().clamp(1, briefing.totalLaps);

    // What the plan rests on, for the driver (and the "what changed" dialog).
    final pitMeasured = measuredPitStopTimeLossSeconds != null && measuredPitStopTimeLossSeconds > 0;
    final basis = <String>[
      measuredPercentPerLap != null && measuredPercentPerLap > 0
          ? 'Fuel ${map1PercentPerLap.toStringAsFixed(2)}%/lap, measured from your laps.'
          : baseFuel != null && km != null
          ? 'Fuel ${map1PercentPerLap.toStringAsFixed(2)}%/lap, from your laps in earlier rounds '
                '(${baseFuel.tracks.join(', ')}) scaled to x${_x(briefing.fuelConsumptionMultiplier)} and '
                '${km.toStringAsFixed(1)} km -- practice here to measure it.'
          : 'Fuel ${map1PercentPerLap.toStringAsFixed(2)}%/lap, assumed -- no practice laps to measure it yet.',
      pitMeasured
          ? 'Pit stop ${pitStopTimeLossSeconds.toStringAsFixed(1)}s, from GT7\'s Pit Stop Time you entered.'
          : 'Pit stop ${pitStopTimeLossSeconds.toStringAsFixed(1)}s, a typical figure -- enter GT7\'s Pit Stop Time for yours.',
    ];

    // Tyre wear per lap for each tyre allowed, from your laps in earlier
    // rounds scaled to this round's wear setting and lap length.
    final wearPerLap = <String, double>{};
    if (trackLengthMeters != null) {
      for (final compound in briefing.availableTireCompounds) {
        final rate = baseRates.wear[compound];
        if (rate == null) continue;
        final perLap = rate.perLap(briefing.tyreWearMultiplier, trackLengthMeters);
        wearPerLap[compound] = perLap;
        basis.add('${_shortTyre(compound)}: about ${perLap.toStringAsFixed(1)}% wear a lap, so '
            '${tyreLifeLaps(perLap)} laps to ${wornOutPercent.toStringAsFixed(0)}% left -- from your laps '
            '(${rate.tracks.join(', ')}) scaled to x${_x(briefing.tyreWearMultiplier)} and ${km!.toStringAsFixed(1)} km.');
      }
    }

    // A wet race: stops where the weather changes tyre, not just for fuel.
    final forecast = briefing.weather;
    if (forecast != null && forecast.phases.any((p) => p.tyre != WeatherTyre.slicks)) {
      return _weatherPlan(
        briefing,
        forecast,
        basis: basis,
        wetPace: wetPace,
        fuelRangeLaps: fuelRangeLaps,
        assumedPercentPerLap: assumedPercentPerLap,
        pitStopTimeLossSeconds: pitStopTimeLossSeconds,
        pitStopTimeIsMeasured: measuredPitStopTimeLossSeconds != null && measuredPitStopTimeLossSeconds > 0,
        fuelMap: fuelMap,
      );
    }

    // Stint length is the SHORTER of the fuel-range and the maximum
    // tyre stint cap (0 = no cap, i.e. fuel-range-only as before) --
    // mirrors standard sim-racing pit-calculator practice: tyre grip
    // can fall off a cliff well before the tank runs dry.
    // With no cap in the brief, the longest-lasting tyre you have wear
    // figures for sets it.
    final tyreLives = [
      for (final perLap in wearPerLap.values) tyreLifeLaps(perLap),
    ];
    final measuredCap = tyreLives.isEmpty ? 0 : tyreLives.reduce((a, b) => a > b ? a : b).clamp(1, briefing.totalLaps);
    final tyreCap = briefing.maxTyreStintLaps > 0 ? briefing.maxTyreStintLaps : measuredCap;
    final lapsPerTank = tyreCap > 0 && tyreCap < fuelRangeLaps ? tyreCap : fuelRangeLaps;

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

    final constraintNote = tyreCap > 0 && lapsPerTank == tyreCap && lapsPerTank < fuelRangeLaps
        ? briefing.maxTyreStintLaps > 0
              ? ' Stint length is capped by the ${briefing.maxTyreStintLaps}-lap tyre limit, not fuel range.'
              : ' Stint length is capped by tyre wear ($tyreCap laps), not fuel range.'
        : '';
    // A stint longer than its tyre lasts.
    final stintStarts = [1, for (final p in pitStops) p.lap];
    for (var i = 0; i < stintStarts.length; i++) {
      final compound = compoundsForStints[i];
      final perLap = wearPerLap[compound];
      if (perLap == null) continue;
      final length = (i + 1 < stintStarts.length ? stintStarts[i + 1] : briefing.totalLaps + 1) - stintStarts[i];
      final life = tyreLifeLaps(perLap);
      if (length > life) {
        basis.add('Stint ${i + 1} is $length laps on ${_shortTyre(compound)}, which last about $life -- '
            'expect them to go off.');
      }
    }
    final reserveNote = ' Keeps ${reservePercent.toStringAsFixed(1)}% fuel '
        '${briefing.finishFuelReservePercent > 0 ? '' : '(half a lap) '}in reserve at the finish.';

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
      basis: basis,
      fuelMap: fuelMap,
    );
  }

  /// A wet race's plan from the brief's weather: the race split into
  /// spells -- dry (slicks) and wet (Inters or Wets) -- with a tyre stop
  /// at each change of spell, roughly where the slots put it (they're
  /// taken as evenly spread; the live calls off the water gauge pick the
  /// real lap). Back-to-back wet weathers (R06 then R05) are one spell on
  /// the tyre covering more of its laps, rather than an extra stop for
  /// Wets -> Inters (practice wet testing shows whether that holds).
  /// Every stop refuels; a fuel-only stop is added where a spell runs
  /// longer than a tank.
  static RaceStrategy _weatherPlan(
    RaceBriefing briefing,
    WeatherForecast forecast, {
    required List<String> basis,
    WetPaceTable? wetPace,
    required int fuelRangeLaps,
    required double assumedPercentPerLap,
    required double pitStopTimeLossSeconds,
    required bool pitStopTimeIsMeasured,
    required int fuelMap,
  }) {
    final totalLaps = briefing.totalLaps;
    final slick = [
      for (final c in _dryHardnessOrder)
        if (briefing.availableTireCompounds.contains(c)) c,
    ].firstOrNull ?? 'Racing Hard';

    // Spells: consecutive dry phases, or consecutive wet ones.
    final spells = <(String, int, int, String)>[]; // (compound, firstLap, lastLap, why)
    final phases = forecast.phases;
    var i = 0;
    while (i < phases.length) {
      final wet = phases[i].tyre != WeatherTyre.slicks;
      final group = <WeatherPhase>[];
      while (i < phases.length && (phases[i].tyre != WeatherTyre.slicks) == wet) {
        group.add(phases[i++]);
      }
      final (first, _) = forecast.lapsOfPhase(group.first, totalLaps);
      final (_, last) = forecast.lapsOfPhase(group.last, totalLaps);
      if (last < first) continue;
      String compound;
      String why;
      if (!wet) {
        compound = slick;
        why = 'track dry';
      } else {
        final slots = [for (final p in group) for (var s = p.firstSlot; s <= p.lastSlot; s++) forecast.slots[s - 1].code];
        why = 'rain (${slots.join('/')})';
        // Your own wet testing first: over the spell's slots, the time
        // Wets would gain (or lose) on Inters where both were tested.
        var measuredMs = 0.0;
        final measuredIn = <String>[];
        for (final p in group) {
          for (var slot = p.firstSlot; slot <= p.lastSlot; slot++) {
            final code = forecast.slots[slot - 1].code;
            final wets = wetPace?.pace(code, WeatherTyre.wets);
            final inters = wetPace?.pace(code, WeatherTyre.inters);
            if (wets == null || inters == null) continue;
            final (a, b) = forecast.lapsOfSlot(slot, totalLaps);
            measuredMs += (inters.lapMs - wets.lapMs) * (b - a + 1);
            if (!measuredIn.contains(code)) measuredIn.add(code);
          }
        }
        WeatherTyre tyre;
        if (measuredIn.isNotEmpty) {
          tyre = measuredMs > 0 ? WeatherTyre.wets : WeatherTyre.inters;
          final faster = tyre == WeatherTyre.wets ? 'Wets' : 'Inters';
          basis.add('Laps $first-$last: $faster, from your wet testing in ${measuredIn.join('/')} '
              '(about ${(measuredMs.abs() / 1000).toStringAsFixed(1)}s quicker over the spell).');
        } else {
          // Otherwise the community guide: the wet tyre covering more of it.
          final laps = <WeatherTyre, int>{};
          for (final p in group) {
            final (a, b) = forecast.lapsOfPhase(p, totalLaps);
            laps[p.tyre] = (laps[p.tyre] ?? 0) + (b - a + 1);
          }
          tyre = laps.entries.reduce((a, b) => b.value > a.value || (b.value == a.value && b.key == WeatherTyre.inters) ? b : a).key;
          basis.add('Laps $first-$last: ${tyre == WeatherTyre.wets ? 'Wets' : 'Inters'}, from the community tyre guide for '
              '${slots.join('/')} -- run the wet stint tests to decide it from your own pace.');
        }
        compound = tyre == WeatherTyre.wets ? 'Heavy Wet' : 'Intermediate';
      }
      spells.add((compound, first, last, why));
    }

    final pitStops = <PlannedPitStop>[];
    for (final (n, (compound, first, last, why)) in spells.indexed) {
      if (n > 0) {
        pitStops.add(PlannedPitStop(
          lap: first,
          tireCompound: compound,
          reasoning: '$compound for the ${why == 'track dry' ? 'dry spell' : why}, about laps $first-$last; refuel too. '
              'The water gauge in the race calls the exact lap.',
        ));
      }
      // Fuel-only stops if this spell runs longer than a tank.
      var from = first;
      while (last - from + 1 > fuelRangeLaps) {
        from += fuelRangeLaps;
        pitStops.add(PlannedPitStop(
          lap: from,
          tireCompound: compound,
          reasoning: 'Refuel (fresh $compound) -- the spell runs longer than a tank.',
        ));
      }
    }
    final stopLaps = <int>{};
    pitStops.retainWhere((p) => p.lap > 1 && p.lap < totalLaps && stopLaps.add(p.lap));

    final startingTire = spells.isEmpty ? slick : spells.first.$1;
    final summary = '${pitStops.length}-stop wet-weather plan from the brief\'s weather: start on $startingTire'
        '${pitStops.isEmpty ? '' : ', then ${pitStops.map((p) => '${p.tireCompound} about lap ${p.lap}').join(', ')}'}. '
        'Laps assume the weather slots are spread evenly; in the race the water gauge calls each stop.';

    return RaceStrategy(
      pitStops: pitStops,
      startingTireCompound: startingTire,
      summary: summary,
      assumedPercentPerLap: assumedPercentPerLap,
      totalEstimatedTimeLossSeconds: pitStops.length * pitStopTimeLossSeconds,
      pitStopTimeIsMeasured: pitStopTimeIsMeasured,
      basis: basis,
      fuelMap: fuelMap,
    );
  }

  static String _x(double multiplier) =>
      multiplier == multiplier.roundToDouble() ? multiplier.toStringAsFixed(0) : multiplier.toString();

  static String _shortTyre(String compound) => switch (compound) {
    'Heavy Wet' => 'Wets',
    'Intermediate' => 'Inters',
    _ => '${compound.replaceFirst('Racing ', '')}s',
  };

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
