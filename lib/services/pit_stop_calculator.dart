import '../models/race_briefing.dart';
import '../models/race_plan_inputs.dart';
import '../models/race_strategy.dart';
import '../models/weather_forecast.dart';
import 'base_rates.dart';
import 'dry_tyre_pace.dart';
import 'fuel_map_measurement.dart';
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

  /// GT7's fuel maps (MFD): 1 is full power; each map up burns less fuel
  /// and gives up pace. From the driver's figures (Map 2-6: about 4-20%
  /// less power, fuel saved 8-14% / 16-20% / 24-34% / 32-41% / 40-50%,
  /// lap time 0.5-0.8% / 1.0-1.5% / 1.5-2.2% / 2.0-3.0% / 2.5-4.0%).
  /// The saving taken is the LOW end of each range, so a plan that saves
  /// a stop on a leaner map doesn't run dry if it saves less; the pace
  /// cost is the middle of each range.
  static const int maxFuelMap = 6;
  static const List<double> fuelMapSaving = [0, 0.08, 0.16, 0.24, 0.32, 0.40];
  static const List<double> fuelMapLapTimeLoss = [0, 0.0065, 0.0125, 0.0185, 0.025, 0.0325];

  /// The hopeful end of the same ranges -- the most fuel saved, the
  /// least pace lost -- for whether a map is worth testing at all.
  static const List<double> fuelMapSavingBest = [0, 0.14, 0.20, 0.34, 0.41, 0.50];
  static const List<double> fuelMapLapTimeLossBest = [0, 0.005, 0.010, 0.015, 0.020, 0.025];

  /// A lap's length in seconds when there's no lap time to go on: about
  /// 160 km/h, typical of Gr.3/Gr.4 race pace.
  static const double assumedSecondsPerKm = 22.5;

  static int _mapIndex(int map) => map.clamp(1, maxFuelMap) - 1;

  /// Fuel use on [map] against Map 1.
  static double fuelMapFactor(int map) => 1 - fuelMapSaving[_mapIndex(map)];

  /// Seconds a lap given up on [map] against Map 1, on a [lapSeconds] lap.
  static double fuelMapPaceCost(int map, double lapSeconds) => lapSeconds * fuelMapLapTimeLoss[_mapIndex(map)];

  /// Dry tire compounds in hardness order, hardest (longest-lasting,
  /// least grip) first -- used to pick a sensible default starting
  /// compound and stint assignment when the briefing doesn't mandate
  /// a specific one.
  static const List<String> _dryHardnessOrder = ['Racing Hard', 'Racing Medium', 'Racing Soft'];

  /// The dry compounds the planner picks between.
  static const List<String> dryCompounds = _dryHardnessOrder;

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

  /// Dry tyre wear before the driver has any laps of their own on a
  /// compound: percent of the tyre a lap, per 1x wear multiplier per km
  /// (scaled like BaseRate). From the developer's own Gr.3 laps, Nov
  /// 2026: Hards 0.074 (80 laps, Nürburgring Sprint x6 and Sainte-Croix C
  /// x2); Softs 0.65, from Alsace Village (Reverse) x2 -- 70% gone after
  /// 10 laps -- the harder end of what was seen (the Sprint and
  /// Sainte-Croix laps said about half that), so a first plan errs on
  /// stopping early, not on running a tyre it can't; Mediums, unmeasured,
  /// halfway between on a ratio scale. A first strategy's stints then end
  /// where the tyres would, not only where the fuel does; your own laps
  /// replace them.
  static const Map<String, double> assumedWearPerXPerKm = {
    'Racing Hard': 0.074,
    'Racing Medium': 0.22,
    'Racing Soft': 0.65,
  };

  /// A set counts as worn out at this much tyre left (the HUD gauge):
  /// a tyre's life is the laps it takes to wear down to it.
  static const double wornOutPercent = 30;

  /// Laps a [wearPerLap] tyre lasts (see [wornOutPercent]).
  static int tyreLifeLaps(double wearPerLap) => wearPerLap <= 0 ? 999 : ((100 - wornOutPercent) / wearPerLap).floor();

  /// Computes the full deterministic strategy for a given briefing.
  ///
  /// One search over every plan that can work (see [_bestPlan]): how
  /// many stops (the brief's minimum up to [maxExtraStops] beyond the
  /// fewest that can work), where they go, and each stint's tyre and fuel
  /// map. A plan works if every stint's fuel lasts on its map and its
  /// tyre lasts the stint (and the brief's mandatory compound is run).
  /// Of those it takes the quickest: the time in the pits, plus every lap
  /// at its tyre's pace and its map's pace cost.
  ///
  /// The numbers, measured where they can be and assumed otherwise --
  /// the plan's basis says which:
  /// - fuel: [measuredPercentPerLap] (this round's laps), else earlier
  ///   rounds' scaled ([baseRates]), else a typical figure;
  /// - pit stop: [measuredPitStopTimeLossSeconds] (GT7's figure), else a
  ///   typical one;
  /// - tyre wear and life: [baseRates] and how soon a tyre went off here
  ///   ([dryPace]); a tyre with no figure is taken to last;
  /// - tyre pace: [dryPace] (this round's laps); an untimed tyre is put
  ///   [assumedCompoundGap] a step slower than a softer one. Until every
  ///   dry tyre is timed, the tyre pace doesn't count in choosing how
  ///   many stops (only which tyre where);
  /// - fuel maps: Map 1, and a leaner map once this round has measured it
  ///   ([measuredMaps], from a fuel map stint test -- see
  ///   FuelMapMeasurement). A map runs only on the stints that need it.
  ///
  /// If an unmeasured map might make a quicker plan -- on the hopeful end
  /// of the figures ([fuelMapSavingBest], [fuelMapLapTimeLossBest]) --
  /// the plan names it in [RaceStrategy.fuelMapToTest], and the test plan
  /// gets a stint on it.
  ///
  /// A wet race (rain in the brief's weather) is planned from the
  /// forecast instead (see _weatherPlan).
  static RaceStrategy calculate(
    RaceBriefing briefing, {
    double? trackLengthMeters,
    double? measuredPercentPerLap,
    double? measuredPitStopTimeLossSeconds,
    WetPaceTable? wetPace,
    BaseRates baseRates = BaseRates.none,
    int maxFuelMap = PitStopCalculator.maxFuelMap,
    double? lapTimeSeconds,
    Map<int, FuelMapMeasurement> measuredMaps = const {},
    Map<String, DryTyrePace> dryPace = const {},
  }) {
    final totalLaps = briefing.totalLaps < 1 ? 1 : briefing.totalLaps;

    // When the driver has entered GT7's pit stop time, that figure is the
    // whole stop (tyre change included); otherwise a typical pit-lane
    // loss plus the tyre change.
    final pitMeasured = measuredPitStopTimeLossSeconds != null && measuredPitStopTimeLossSeconds > 0;
    final pitLoss = pitMeasured ? measuredPitStopTimeLossSeconds : _defaultPitStopTimeLossSeconds + _tyreChangeLossSeconds;

    // Fuel a lap on Map 1.
    final double map1PerLap;
    final baseFuel = baseRates.fuel;
    final km = trackLengthMeters == null ? null : trackLengthMeters / 1000;
    if (measuredPercentPerLap != null && measuredPercentPerLap > 0) {
      map1PerLap = measuredPercentPerLap;
    } else if (baseFuel != null && trackLengthMeters != null) {
      // Your laps in earlier rounds, scaled to this round's fuel setting
      // and lap length.
      map1PerLap = baseFuel.perLap(briefing.fuelConsumptionMultiplier, trackLengthMeters);
    } else {
      final lengthScale = (trackLengthMeters ?? _referenceTrackLengthMeters) / _referenceTrackLengthMeters;
      map1PerLap = _basePercentPerLapAt1x * briefing.fuelConsumptionMultiplier * lengthScale;
    }

    // What the plan rests on, for the driver (and the "what changed" dialog).
    final basis = <String>[
      measuredPercentPerLap != null && measuredPercentPerLap > 0
          ? 'Fuel ${map1PerLap.toStringAsFixed(1)}%/lap, measured from your laps.'
          : baseFuel != null && km != null
          ? 'Fuel ${map1PerLap.toStringAsFixed(1)}%/lap, from your laps in earlier rounds '
                '(${baseFuel.tracks.join(', ')}) scaled to x${_x(briefing.fuelConsumptionMultiplier)} and '
                '${km.toStringAsFixed(1)} km -- practice here to measure it.'
          : 'Fuel ${map1PerLap.toStringAsFixed(1)}%/lap, assumed -- no practice laps to measure it yet.',
      pitMeasured
          ? 'Pit stop ${pitLoss.toStringAsFixed(1)}s, from GT7\'s Pit Stop Time you entered.'
          : 'Pit stop ${pitLoss.toStringAsFixed(1)}s, a typical figure -- enter GT7\'s Pit Stop Time for yours.',
    ];

    // Tyre wear per lap for each tyre allowed, from your laps (this
    // round's and earlier ones') scaled to this round's wear setting and
    // lap length.
    // A dry tyre with none: the typical figure (see assumedWearPerXPerKm).
    final wearPerLap = <String, double>{};
    final assumedWear = <String>{};
    final wearKm = (trackLengthMeters ?? _referenceTrackLengthMeters) / 1000;
    for (final compound in briefing.availableTireCompounds) {
      final rate = trackLengthMeters == null ? null : baseRates.wear[compound];
      if (rate != null) {
        final perLap = rate.perLap(briefing.tyreWearMultiplier, trackLengthMeters!);
        wearPerLap[compound] = perLap;
        basis.add('${_shortTyre(compound)}: about ${perLap.toStringAsFixed(1)}% wear a lap, so '
            '${tyreLifeLaps(perLap)} laps to ${wornOutPercent.toStringAsFixed(0)}% left -- from your laps '
            '(${rate.tracks.join(', ')}) scaled to x${_x(briefing.tyreWearMultiplier)} and ${km!.toStringAsFixed(1)} km.');
        continue;
      }
      final typical = assumedWearPerXPerKm[compound];
      if (typical == null || briefing.tyreWearMultiplier <= 0) continue;
      final perLap = typical * briefing.tyreWearMultiplier * wearKm;
      wearPerLap[compound] = perLap;
      assumedWear.add(compound);
      basis.add('${_shortTyre(compound)}: about ${perLap.toStringAsFixed(1)}% wear a lap, so '
          '${tyreLifeLaps(perLap)} laps to ${wornOutPercent.toStringAsFixed(0)}% left -- assumed (a typical Gr.3 figure, '
          'scaled to x${_x(briefing.tyreWearMultiplier)} and ${wearKm.toStringAsFixed(1)} km) until your laps measure it.');
    }

    // How long each tyre lasts: the wear figure, or sooner if it went off
    // in practice here -- and never past the brief's stint limit.
    final measuredLife = <String, int>{
      for (final c in {...wearPerLap.keys, ...dryPace.keys})
        if (wearPerLap[c] != null || dryPace[c]?.dropOffAfterLaps != null)
          c: [
            if (wearPerLap[c] case final w?) tyreLifeLaps(w),
            if (dryPace[c]?.dropOffAfterLaps case final d?) d,
          ].reduce((a, b) => a < b ? a : b),
    };
    for (final MapEntry(key: c, value: p) in dryPace.entries) {
      final d = p.dropOffAfterLaps;
      if (d != null && (wearPerLap[c] == null || d < tyreLifeLaps(wearPerLap[c]!))) {
        basis.add('${_shortTyre(c)}: went off after $d laps in practice here.');
      } else if (p.heldPaceLaps case final n? when d == null) {
        // Measured: the pace held this far. Beyond it, the wear figure's
        // projection to the drop-off.
        final worn = p.heldPaceWornPercent;
        basis.add('${_shortTyre(c)}: held their pace for all $n laps of a stint in practice here'
            '${worn == null ? '' : ' (${worn.round()}% worn)'} -- any further is projected from the wear.');
      }
    }
    final cap = briefing.maxTyreStintLaps > 0 ? briefing.maxTyreStintLaps : null;
    int lifeOf(String c) {
      final life = measuredLife[c] ?? 999;
      return (cap != null && cap < life ? cap : life).clamp(1, 999);
    }

    // The lap a fuel map's pace cost is a share of: your lap time here,
    // else one guessed from the lap length.
    final lap = lapTimeSeconds != null && lapTimeSeconds > 0
        ? lapTimeSeconds
        : (trackLengthMeters ?? _referenceTrackLengthMeters) / 1000 * assumedSecondsPerKm;

    // The dry tyres to choose between, fastest first.
    var tyres = [
      for (final c in _dryHardnessOrder.reversed)
        if (briefing.availableTireCompounds.contains(c)) c,
    ];
    if (tyres.isEmpty) {
      tyres = [
        for (final c in briefing.availableTireCompounds)
          if (c != 'Intermediate' && c != 'Heavy Wet') c,
      ];
    }
    if (tyres.isEmpty) tyres = [briefing.availableTireCompounds.firstOrNull ?? 'Racing Medium'];
    bool timed(String c) => dryPace[c]?.hasPace ?? false;
    final allTimed = tyres.every(timed);
    final pace = _tyrePaces(tyres, dryPace, lap);
    tyres.sort((a, b) => pace[a]!.compareTo(pace[b]!));

    // Fuel maps: Map 1, the ones measured here, and -- for whether one is
    // worth a test -- the rest on the hopeful figures.
    final real = [
      _FuelMapOption(1, map1PerLap, 0, measured: true),
      if (measuredPercentPerLap != null && measuredPercentPerLap > 0)
        for (final m in measuredMaps.values)
          if (m.map >= 2 && m.map <= maxFuelMap)
            _FuelMapOption(m.map, map1PerLap * m.fuelFactor, m.lapTimeLoss ?? fuelMapLapTimeLoss[_mapIndex(m.map)],
                measured: true, measurement: m),
    ];
    final hopeful = [
      ...real,
      for (var m = 2; m <= maxFuelMap; m++)
        if (!real.any((o) => o.map == m))
          _FuelMapOption(m, map1PerLap * (1 - fuelMapSavingBest[_mapIndex(m)]), fuelMapLapTimeLossBest[_mapIndex(m)], measured: false),
    ];
    int tankLaps(_FuelMapOption m) {
      final reserve = briefing.finishFuelReservePercent > 0 ? briefing.finishFuelReservePercent : finishReserveLaps * m.perLap;
      final usable = (briefing.startingFuelPercent - reserve).clamp(m.perLap, briefing.startingFuelPercent);
      return (usable / m.perLap).floor().clamp(1, totalLaps);
    }

    // A wet race: stops where the weather changes tyre, not just for fuel.
    final forecast = briefing.weather;
    if (forecast != null && forecast.phases.any((p) => p.tyre != WeatherTyre.slicks)) {
      final map1Tank = tankLaps(real.first);
      // A dry spell's slick: the fastest that lasts its stints (the spell,
      // or a tank if the spell is longer), else the longest-lasting.
      String slickFor(int laps) {
        final stint = laps < map1Tank ? laps : map1Tank;
        return tyres.firstWhere((c) => lifeOf(c) >= stint, orElse: () => tyres.reduce((a, b) => lifeOf(b) > lifeOf(a) ? b : a));
      }

      return _weatherPlan(
        briefing,
        forecast,
        basis: basis,
        wetPace: wetPace,
        fuelRangeLaps: map1Tank,
        assumedPercentPerLap: map1PerLap,
        pitStopTimeLossSeconds: pitLoss,
        pitStopTimeIsMeasured: pitMeasured,
        fuelMap: 1,
        slickFor: slickFor,
      );
    }

    final mandatory = briefing.mandatoryTyreCompound != 'N/A' && tyres.contains(briefing.mandatoryTyreCompound)
        ? briefing.mandatoryTyreCompound
        : null;
    final search = _Search(
      totalLaps: totalLaps,
      tyres: tyres,
      pace: pace,
      lifeOf: lifeOf,
      lap: lap,
      pitLoss: pitLoss,
      mandatory: mandatory,
      tankLaps: tankLaps,
    );
    // Planned by the quickest; until every tyre is timed, the tyres' pace
    // doesn't decide the number of stops.
    double key(_Plan p) => p.pitSeconds + p.mapSeconds + (allTimed ? p.tyreSeconds : 0);
    (_Plan, _Plan)? plan(List<_FuelMapOption> maps, {int? minStops}) =>
        _bestPlan(search, maps, minStops ?? briefing.mandatoryPitStopCount, key);

    final (planned, fewest) = plan(real)!;

    // The grid: from the front third, the faster tyre first (to hold
    // track position); lower down, the slower one first. A stint's time
    // doesn't depend on where it runs, so the order costs nothing on the
    // plan's figures. Not entered: as planned.
    final gridPosition = briefing.gridPosition != null && briefing.gridPosition! > 0 ? briefing.gridPosition : null;
    final gridCars = briefing.gridSize ?? RaceBriefing.defaultGridSize;
    final slowFirst = gridPosition == null ? null : !startsNearFront(gridPosition, gridCars);
    _Plan forGrid(_Plan p) => slowFirst == null ? p : p.ordered(pace, slowFirst: slowFirst);
    final chosen = forGrid(planned);

    // The brief's minimum, above what fuel and tyres need.
    final (_, needed) = plan(real, minStops: 0)!;
    if (briefing.mandatoryPitStopCount > needed.stops) {
      basis.add('The brief requires ${briefing.mandatoryPitStopCount} stop${briefing.mandatoryPitStopCount == 1 ? '' : 's'}; '
          'fuel${measuredLife.isNotEmpty || cap != null ? ' and tyres' : ''} need only ${needed.stops} -- so a fuel map can\'t save one.');
    }

    // Each tyre run, and why.
    basis.addAll(_tyreNotes(
      chosen,
      tyres,
      dryPace,
      {
        for (final MapEntry(key: c, value: life) in measuredLife.entries)
          if (!assumedWear.contains(c) || dryPace[c]?.dropOffAfterLaps != null) c: life,
      },
      cap,
      mandatory,
      search,
    ));

    // An extra stop that pays.
    if (chosen.stops > fewest.stops) {
      final extra = chosen.stops - fewest.stops;
      basis.add('${extra == 1 ? 'An extra stop' : '$extra extra stops'} for ${_describe(chosen)}: about '
          '${(key(fewest) - key(chosen)).round()}s quicker than ${_describe(fewest)} on '
          '${_stops(fewest.stops)} -- the faster laps more than pay for the stop.');
    }

    // The grid, when the plan runs a faster and a slower tyre.
    if (_gridNote(chosen, pace, gridPosition, gridCars, briefing.gridSize != null) case final note?) basis.add(note);

    // A leaner map, where it runs.
    final lean = {for (final m in chosen.maps) if (m.map > 1) m.map: m};
    if (lean.isNotEmpty) {
      final (map1Only, _) = plan([real.first])!;
      final lines = <String>[];
      for (final m in lean.values) {
        final stints = [for (var i = 0; i < chosen.maps.length; i++) if (chosen.maps[i].map == m.map) i + 1];
        final laps = [for (final s in stints) chosen.lengths[s - 1]].fold<int>(0, (a, b) => a + b);
        final measured = m.measurement!;
        lines.add('Fuel Map ${m.map} for stint${stints.length == 1 ? '' : 's'} ${stints.join(', ')} ($laps laps): '
            '${((1 - measured.fuelFactor) * 100).round()}% less fuel, measured over ${measured.laps} laps '
            '(${m.perLap.toStringAsFixed(1)}%/lap), for about ${(lap * m.lapTimeLoss).toStringAsFixed(1)}s a lap'
            '${measured.lapTimeLoss == null ? ' (assumed)' : ', measured'} -- Map 1 for the rest. '
            '${map1Only.stops > chosen.stops ? '${_stops(map1Only.stops - chosen.stops)} fewer than Map 1 all race' : 'Quicker than Map 1 all race'}'
            ', about ${(key(map1Only) - key(chosen)).round()}s over the race.');
      }
      basis.insertAll(1, lines);
    }

    // Might an unmeasured map pay? On the hopeful end of the figures.
    int? toTest;
    if (hopeful.length > real.length) {
      final (best, _) = plan(hopeful)!;
      final untested = [for (final m in best.maps) if (!m.measured) m];
      if (untested.isNotEmpty && key(best) < key(chosen) - 0.5) {
        final m = untested.reduce((a, b) => b.map > a.map ? b : a);
        toTest = m.map;
        basis.add('Fuel Map ${m.map} might ${best.stops < chosen.stops ? 'save a stop (${_stops(chosen.stops)} as planned, '
                '${_stops(best.stops)} ' : 'pay (about ${(key(chosen) - key(best)).round()}s quicker '}'
            'if it saves up to ${(fuelMapSavingBest[_mapIndex(m.map)] * 100).round()}% fuel for '
            '${(lap * fuelMapLapTimeLossBest[_mapIndex(m.map)]).toStringAsFixed(1)}s a lap) -- run the Map ${m.map} stint test '
            'to measure it. Until then the plan runs only the maps you\'ve measured.');
      }
    }

    // Plan B: the quickest with a different number of stops or a
    // different set of tyres -- to switch to mid-race.
    double raceSeconds(_Plan p) => p.pitSeconds + p.mapSeconds + p.tyreSeconds;
    RaceStrategy alternative(String name, _Plan p, String why) {
      final behind = (raceSeconds(p) - raceSeconds(chosen)).clamp(0.0, double.infinity);
      final summary = '$name: ${_describe(p)}, ${_stops(p.stops)}'
          '${p.stops == 0 ? '' : ' (lap${p.stops == 1 ? '' : 's'} ${p.stopLaps.join(', ')})'} -- $why, about ${behind.round()}s slower'
          '${allTimed ? '' : ' on the estimated tyre pace'}. Switch to it if Plan A stops working.';
      // (before the line on a map worth testing, which stays last)
      basis.insert(toTest == null ? basis.length : basis.length - 1, summary);
      return RaceStrategy(
        pitStops: _stopsOf(p, mandatory),
        startingTireCompound: p.tyres.first,
        summary: summary,
        assumedPercentPerLap: p.maps.first.perLap,
        totalEstimatedTimeLossSeconds: p.stops * pitLoss,
        pitStopTimeIsMeasured: pitMeasured,
        fuelMap: p.maps.first.map,
        secondsBehindPlanA: behind,
      );
    }

    // The alternatives: a different number of stops or set of tyres, and
    // -- with Plan A on one tyre -- the quickest on more than one. Plan B
    // is the quicker of them, Plan C the other.
    final alternatives = <(_Plan, String)>[];
    final b = switch (_planB(search, real, chosen, fewest.stops, raceSeconds)) { final p? => forGrid(p), null => null };
    if (b != null) {
      alternatives.add((
        b,
        b.stops != chosen.stops
            ? '${b.stops > chosen.stops ? '${_stops(b.stops - chosen.stops)} more' : '${_stops(chosen.stops - b.stops)} fewer'}'
                  '${chosen.maps.any((m) => m.map > 1) && b.maps.every((m) => m.map == 1) ? ', no fuel saving' : ''}'
            : 'different tyres',
      ));
    }
    final c = switch (_planC(search, real, chosen, fewest.stops, raceSeconds)) { final p? => forGrid(p), null => null };
    if (c != null && (b == null || !_same(b, c))) {
      alternatives.add((c, 'runs ${[for (final t in tyres) if (c.tyres.contains(t)) _shortTyre(t)].join(' and ')}'));
    }
    alternatives.sort((x, y) => raceSeconds(x.$1).compareTo(raceSeconds(y.$1)));
    final planB = alternatives.isEmpty ? null : alternative('Plan B', alternatives[0].$1, alternatives[0].$2);
    final planC = alternatives.length < 2 ? null : alternative('Plan C', alternatives[1].$1, alternatives[1].$2);

    // The plan.
    final pitStops = _stopsOf(chosen, mandatory);
    final startingTire = chosen.tyres.first;

    final map1Tank = tankLaps(real.first);
    final longestLife = [for (final c in tyres) lifeOf(c)].reduce((a, b) => a > b ? a : b);
    final constraintNote = longestLife < map1Tank && chosen.stops > 0
        ? cap != null && longestLife == cap
              ? ' Stint length is capped by the $cap-lap tyre limit, not fuel range.'
              : ' Stint length is capped by tyre wear ($longestLife laps), not fuel range.'
        : '';
    final lastMap = chosen.maps.last;
    final reservePercent = briefing.finishFuelReservePercent > 0 ? briefing.finishFuelReservePercent : finishReserveLaps * lastMap.perLap;
    final reserveNote = ' Keeps ${reservePercent.toStringAsFixed(1)}% fuel '
        '${briefing.finishFuelReservePercent > 0 ? '' : '(half a lap) '}in reserve at the finish.';
    final mapNote = lean.isEmpty
        ? ''
        : 'Run ${[
            for (final m in lean.keys)
              'Fuel Map $m for stint${chosen.maps.where((o) => o.map == m).length == 1 ? '' : 's'} '
                  '${[for (var i = 0; i < chosen.maps.length; i++) if (chosen.maps[i].map == m) i + 1].join(', ')}',
          ].join(' and ')}${chosen.maps.any((o) => o.map == 1) ? ', Map 1 for the rest' : ''}. ';

    final summary = chosen.stops == 0
        ? '${mapNote}No pit stops needed -- starting fuel and $startingTire tires last the full $totalLaps-lap race.$reserveNote'
        : '$mapNote${chosen.stops}-stop strategy starting on $startingTire, pitting at '
            '${pitStops.map((p) => 'lap ${p.lap} (${p.tireCompound})').join(', ')} to refuel'
            '${mandatory != null ? ' and fit the mandatory $mandatory tire' : ''}.'
            '$constraintNote$reserveNote';

    return RaceStrategy(
      pitStops: pitStops,
      startingTireCompound: startingTire,
      summary: summary,
      assumedPercentPerLap: chosen.maps.first.perLap,
      totalEstimatedTimeLossSeconds: chosen.stops * pitLoss,
      pitStopTimeIsMeasured: pitMeasured,
      basis: basis,
      fuelMap: chosen.maps.first.map,
      fuelMapToTest: toTest,
      planB: planB,
      planC: planC,
      inputs: RacePlanInputs(
        totalLaps: totalLaps,
        tyres: [
          for (final c in tyres) RacePlanTyre(c, lapSeconds: pace[c]!, lifeLaps: lifeOf(c), wearPerLap: wearPerLap[c]),
        ],
        maps: [for (final m in real) RacePlanMap(m.map, perLap: m.perLap, lapTimeLoss: m.lapTimeLoss)],
        lapSeconds: lap,
        pitLossSeconds: pitLoss,
        mandatoryTyre: mandatory,
        tankPercent: briefing.startingFuelPercent,
        finishReservePercent: briefing.finishFuelReservePercent,
      ),
    );
  }

  /// The front third of the grid (P1 at least): a start there runs the
  /// faster tyre first, to hold track position. Lower down, the slower
  /// tyre first -- run long while the cars ahead stop, get clear air, then
  /// attack on the faster tyre while they're on worn ones.
  static bool startsNearFront(int position, int cars) => position <= (cars ~/ 3 < 1 ? 1 : cars ~/ 3);

  /// The grid line in the plan's reasoning: which tyre first, and why --
  /// for [position] if entered, else both cases. Null when [plan] runs one
  /// tyre (or tyres of the same pace).
  static String? _gridNote(_Plan plan, Map<String, double> pace, int? position, int cars, bool carsEntered) {
    final run = plan.tyres.toSet().toList()..sort((a, b) => pace[a]!.compareTo(pace[b]!));
    if (run.length < 2 || pace[run.last]! - pace[run.first]! < _Search._same) return null;
    final fast = _shortTyre(run.first), slow = _shortTyre(run.last);
    final cut = cars ~/ 3 < 1 ? 1 : cars ~/ 3;
    const same = 'Same stops, the same race time on the plan\'s figures';
    if (position == null) {
      return 'Grid not entered: from the front third (P1-P$cut of $cars), run the $fast first to hold track position; '
          'from P${cut + 1} down, the $slow first -- you run long while the cars ahead stop, get clear air, then attack '
          'on fresh $fast while they\'re on worn tyres. $same. Enter your grid position after qualifying and generate again.';
    }
    final of = carsEntered ? ' of $cars' : '';
    return startsNearFront(position, cars)
        ? 'Starting P$position$of: $fast first to hold track position. The $slow first would be the same stops and '
              'the same race time on the plan\'s figures, if you\'d rather go long.'
        : 'Starting P$position$of: $slow first -- you run long while the cars ahead stop, get clear air, then attack on '
              'fresh $fast while they\'re on worn tyres. $same.';
  }

  /// [plan] with its stints in tyre-pace order -- the slowest tyre first
  /// ([slowFirst]) or the fastest -- for the grid (see startsNearFront),
  /// with its stops and summary to match. A stint's time doesn't depend
  /// on where it runs. [plan] as it is if it can't be reordered (no
  /// inputs: a wet race) or already is.
  static RaceStrategy withTyreOrder(RaceStrategy plan, {required bool slowFirst}) {
    final inputs = plan.inputs;
    if (inputs == null || plan.pitStops.isEmpty) return plan;
    final lengths = stintLengths(inputs.totalLaps, [for (final p in plan.pitStops) p.lap]);
    final tyres = plan.stintTyres;
    final maps = plan.stintMaps;
    if (lengths.length != tyres.length) return plan;
    final pace = {for (final t in inputs.tyres) t.compound: t.lapSeconds};
    if (tyres.any((t) => pace[t] == null)) return plan;
    final order = _paceOrder(tyres, pace, slowFirst: slowFirst);
    if ([for (var i = 0; i < order.length; i++) order[i] == i].every((x) => x)) return plan;
    final t = [for (final i in order) tyres[i]], l = [for (final i in order) lengths[i]], m = [for (final i in order) maps[i]];
    final stops = <PlannedPitStop>[];
    var lap = 0;
    for (var i = 1; i < t.length; i++) {
      lap += l[i - 1];
      stops.add(PlannedPitStop(
        lap: lap,
        tireCompound: t[i],
        fuelMap: m[i],
        reasoning: 'Scheduled refuel and tire change to ${t[i]}'
            '${t[i] == inputs.mandatoryTyre ? ' (mandatory compound)' : ''}'
            '${m[i] != m[i - 1] ? ', then Fuel Map ${m[i]}' : ''}'
            ' for a ${l[i]}-lap stint.',
      ));
    }
    final summary = '${stops.length}-stop strategy starting on ${t.first}, pitting at '
        '${stops.map((p) => 'lap ${p.lap} (${p.tireCompound})').join(', ')} -- '
        '${slowFirst ? 'the slower tyre first, for a start lower down the grid' : 'the faster tyre first, for a start near the front'}.';
    return RaceStrategy(
      pitStops: stops,
      startingTireCompound: t.first,
      summary: summary,
      assumedPercentPerLap: inputs.maps.where((x) => x.map == m.first).map((x) => x.perLap).firstOrNull ?? plan.assumedPercentPerLap,
      totalEstimatedTimeLossSeconds: plan.totalEstimatedTimeLossSeconds,
      pitStopTimeIsMeasured: plan.pitStopTimeIsMeasured,
      testsDone: plan.testsDone,
      testsPlanned: plan.testsPlanned,
      basis: plan.basis,
      fuelMap: m.first,
      fuelMapToTest: plan.fuelMapToTest,
      planB: plan.planB,
      planC: plan.planC,
      secondsBehindPlanA: plan.secondsBehindPlanA,
      inputs: inputs,
    );
  }

  /// Stint indexes in tyre-pace order (slowest first if [slowFirst]),
  /// keeping the plan's order between stints on tyres of the same pace.
  static List<int> _paceOrder(List<String> tyres, Map<String, double> pace, {required bool slowFirst}) =>
      [for (var i = 0; i < tyres.length; i++) i]..sort((a, b) {
        final d = pace[tyres[a]]!.compareTo(pace[tyres[b]]!);
        if (d != 0 && (pace[tyres[a]]! - pace[tyres[b]]!).abs() > _Search._same) return slowFirst ? -d : d;
        return a.compareTo(b);
      });

  /// Would [plan] run in another order for [slowFirst]? (see withTyreOrder)
  static bool tyreOrderDiffers(RaceStrategy plan, {required bool slowFirst}) =>
      !identical(withTyreOrder(plan, slowFirst: slowFirst), plan);

  /// A plan's stops: each one's lap, tyre and the map for the stint after.
  static List<PlannedPitStop> _stopsOf(_Plan plan, String? mandatory, {int lapOffset = 0}) {
    final stopLaps = plan.stopLaps;
    return [
      for (var i = 1; i <= plan.stops; i++)
        PlannedPitStop(
          lap: lapOffset + stopLaps[i - 1],
          tireCompound: plan.tyres[i],
          fuelMap: plan.maps[i].map,
          reasoning: 'Scheduled refuel and tire change to ${plan.tyres[i]}'
              '${plan.tyres[i] == mandatory ? ' (mandatory compound)' : ''}'
              '${plan.maps[i].map != plan.maps[i - 1].map ? ', then Fuel Map ${plan.maps[i].map}' : ''}'
              ' for a ${plan.lengths[i]}-lap stint.',
        ),
    ];
  }

  /// Plan B against [planA]: the quickest plan (by [raceSeconds]) with a
  /// different number of stops -- [fewestStops] up to [maxExtraStops]
  /// more -- or the same number without one of Plan A's tyres. (Not a
  /// plan made to run another tyre: the search would fit it in for a
  /// token lap.) Moving a stop a lap, or only a different map, isn't a
  /// different plan.
  static _Plan? _planB(_Search search, List<_FuelMapOption> maps, _Plan planA, int fewestStops, double Function(_Plan) raceSeconds) {
    final used = planA.tyres.toSet();
    final candidates = <_Plan>[
      for (var n = fewestStops; n <= fewestStops + maxExtraStops && n <= search.totalLaps - 1; n++)
        if (n != planA.stops) ?search.best(n, maps),
      for (final c in used)
        if (c != search.mandatory && search.tyres.length > 1)
          ?search.copyWith(tyres: [for (final t in search.tyres) if (t != c) t]).best(planA.stops, maps),
    ];
    final different = [
      for (final p in candidates)
        if (p.stops != planA.stops || p.tyres.toSet().length != used.length || !p.tyres.toSet().containsAll(used)) p,
    ];
    if (different.isEmpty) return null;
    return different.reduce((a, b) => raceSeconds(b) < raceSeconds(a) - _Search._same ? b : a);
  }

  /// The same stints on the same tyres.
  static bool _same(_Plan a, _Plan b) =>
      a.lengths.length == b.lengths.length &&
      [for (var i = 0; i < a.lengths.length; i++) a.lengths[i] == b.lengths[i] && a.tyres[i] == b.tyres[i]].every((x) => x);

  /// Plan C, when [planA] runs one tyre and more are allowed: the quickest
  /// plan (by [raceSeconds]) running two or more of them -- each set of
  /// two or more tried, all of its tyres run, from [fewestStops] to
  /// [maxExtraStops] more. No stint shorter than half an even one (and 2
  /// laps), so a tyre isn't run for a token lap.
  static _Plan? _planC(_Search search, List<_FuelMapOption> maps, _Plan planA, int fewestStops, double Function(_Plan) raceSeconds) {
    final all = search.tyres;
    if (all.length < 2 || planA.tyres.toSet().length > 1) return null;
    final sets = [
      for (var mask = 1; mask < 1 << all.length; mask++)
        if (mask.toRadixString(2).replaceAll('0', '').length >= 2) [for (var i = 0; i < all.length; i++) if (mask & (1 << i) != 0) all[i]],
    ];
    _Plan? best;
    for (final set in sets) {
      if (search.mandatory != null && search.required.contains(search.mandatory) && !set.contains(search.mandatory)) continue;
      for (var n = fewestStops < 1 ? 1 : fewestStops; n <= fewestStops + maxExtraStops && n <= search.totalLaps - 1; n++) {
        final shortest = (search.totalLaps / (n + 1) / 2).round();
        final p = search
            .copyWith(tyres: set, required: {...search.required, ...set}.toList(), minStintLaps: shortest < 2 ? 2 : shortest)
            .best(n, maps);
        if (p != null && (best == null || raceSeconds(p) < raceSeconds(best) - _Search._same)) best = p;
      }
    }
    return best;
  }

  /// Mid-race: the rest of the race planned again from where the car is,
  /// to [target]'s plan (Plan A or Plan B) -- its number of stops (less
  /// those made) and its tyres, on the figures the strategy was made on
  /// ([inputs]). The stint being run stays on the tyres fitted
  /// ([currentTyre], [lapsOnTyre] laps on them, [tyreLeftPercent] left
  /// if read) with the fuel in the tank ([fuelPercent], at the start of
  /// the lap after [lapsDone]). If [target]'s stops can't work from
  /// here, the fewest more that can (then any tyre).
  ///
  /// The strategy returned is the whole race's -- the stops made
  /// ([stopLapsMade]) first, then the new ones -- so the live calls and
  /// fuel target (which count stops made) follow it. Its [fuelMap] and
  /// the last stop made name the map for the stint being run. Null if
  /// no plan works (or the race is over); [target] itself before lap 1.
  static RaceStrategy? replan(
    RacePlanInputs inputs,
    RaceStrategy target, {
    required int lapsDone,
    required double fuelPercent,
    required String currentTyre,
    required int lapsOnTyre,
    double? tyreLeftPercent,
    List<int> stopLapsMade = const [],
    bool mandatoryRun = false,
    Set<String> tyresRun = const {},
  }) {
    if (lapsDone <= 0 && stopLapsMade.isEmpty) return target;
    final left = inputs.totalLaps - lapsDone;
    if (left < 1) return null;

    final allTyres = [for (final t in inputs.tyres) t.compound];
    final pace = {for (final t in inputs.tyres) t.compound: t.lapSeconds};
    pace.putIfAbsent(currentTyre, () => inputs.tyres.isEmpty ? inputs.lapSeconds : inputs.tyres.last.lapSeconds);
    int lifeOf(String c) => inputs.tyre(c)?.lifeLaps ?? 999;
    int reserveTank(_FuelMapOption m, double fuel) {
      final reserve = inputs.finishReservePercent > 0 ? inputs.finishReservePercent : finishReserveLaps * m.perLap;
      return ((fuel - reserve) / m.perLap).floor();
    }

    // The tyres fitted: their laps left, by laps run and by the wear read.
    var tyreLeft = lifeOf(currentTyre) - lapsOnTyre;
    final wear = inputs.tyre(currentTyre)?.wearPerLap;
    if (tyreLeftPercent != null && wear != null && wear > 0) {
      final byWear = ((tyreLeftPercent - wornOutPercent) / wear).floor();
      if (byWear < tyreLeft) tyreLeft = byWear;
    }
    final first = _FirstStint(
      currentTyre,
      tyreLeft < 1 ? 1 : tyreLeft,
      (m) => reserveTank(m, fuelPercent).clamp(1, left),
    );
    final maps = [for (final m in inputs.maps) _FuelMapOption(m.map, m.perLap, m.lapTimeLoss, measured: true)];
    final mandatory = inputs.mandatoryTyre;
    final owed = mandatory != null && !mandatoryRun ? mandatory : null;
    // A plan on more than one tyre (Plan C) still runs each of them (the
    // mandatory one only while it's owed).
    final mix = target.stintTyres.toSet().length > 1;
    final stillToRun = mix ? [for (final c in target.stintTyres.toSet()) if (c != currentTyre && !tyresRun.contains(c) && c != mandatory) c] : <String>[];
    _Search search(List<String> tyres, {bool keepMix = false}) => _Search(
      totalLaps: left,
      tyres: tyres,
      pace: pace,
      lifeOf: lifeOf,
      lap: inputs.lapSeconds,
      pitLoss: inputs.pitLossSeconds,
      mandatory: mandatory,
      tankLaps: (m) => reserveTank(m, inputs.tankPercent).clamp(1, left),
      required: [?owed, if (keepMix) ...stillToRun],
      first: first,
      minStintLaps: keepMix && stillToRun.isNotEmpty ? 2 : 1,
    );

    // The target's tyres (and the mandatory one, if still owed).
    final planTyres = {...target.stintTyres, ?owed};
    final targetTyres = [for (final c in allTyres) if (planTyres.contains(c)) c];
    final wanted = (target.pitStops.length - stopLapsMade.length).clamp(0, left - 1);
    _Plan? plan;
    for (final (tyres, keepMix) in [if (targetTyres.isNotEmpty && stillToRun.isNotEmpty) (targetTyres, true), if (targetTyres.isNotEmpty) (targetTyres, false), (allTyres, false)]) {
      final s = search(tyres, keepMix: keepMix);
      for (var n = wanted; n <= left - 1 && n <= wanted + maxExtraStops && plan == null; n++) {
        plan = s.best(n, maps);
      }
      for (var n = 0; n < wanted && plan == null; n++) {
        plan = s.best(n, maps);
      }
      if (plan != null) break;
    }
    if (plan == null) return null;

    final runMap = plan.maps.first.map;
    final made = [...stopLapsMade]..sort();
    final newStops = _stopsOf(plan, mandatory, lapOffset: lapsDone);
    final stops = [
      for (final lap in made)
        PlannedPitStop(lap: lap, tireCompound: currentTyre, fuelMap: runMap, reasoning: 'Stop made.'),
      ...newStops,
    ];
    final summary = 'From lap ${lapsDone + 1}: ${_describe(plan)}'
        '${plan.stops == 0 ? ', no more stops' : ', box on lap${plan.stops == 1 ? '' : 's'} ${[for (final p in newStops) p.lap].join(', ')}'}.';
    return RaceStrategy(
      pitStops: stops,
      startingTireCompound: made.isEmpty ? currentTyre : target.startingTireCompound,
      summary: summary,
      assumedPercentPerLap: plan.maps.first.perLap,
      totalEstimatedTimeLossSeconds: plan.stops * inputs.pitLossSeconds,
      pitStopTimeIsMeasured: target.pitStopTimeIsMeasured,
      fuelMap: runMap,
      inputs: inputs,
    );
  }

  /// A tyre with no lap time here is taken to be this share of a lap
  /// slower than the next softer compound (and quicker than the next
  /// harder one) -- enough to rank them, not to decide a stop.
  static const double assumedCompoundGap = 0.005;

  /// Each tyre's lap, seconds: timed here, or put [assumedCompoundGap] a
  /// step from the nearest timed tyre (or from [lap] if none is timed).
  static Map<String, double> _tyrePaces(List<String> tyres, Map<String, DryTyrePace> dryPace, double lap) {
    int hardness(String c) {
      final i = _dryHardnessOrder.indexOf(c);
      return i < 0 ? 0 : _dryHardnessOrder.length - 1 - i;
    }

    final timed = [for (final c in tyres) if (dryPace[c]?.hasPace ?? false) c];
    return {
      for (final c in tyres)
        c: (dryPace[c]?.hasPace ?? false)
            ? dryPace[c]!.lapMs / 1000
            : timed.isEmpty
            ? lap * (1 + assumedCompoundGap * hardness(c))
            : () {
                final ref = timed.reduce((a, b) => (hardness(b) - hardness(c)).abs() < (hardness(a) - hardness(c)).abs() ? b : a);
                return dryPace[ref]!.lapMs / 1000 * (1 + assumedCompoundGap * (hardness(c) - hardness(ref)));
              }(),
    };
  }

  /// Stops a plan may add beyond the fewest that can work.
  static const int maxExtraStops = 2;

  /// A plan with more stops has to be at least this much quicker.
  static const double extraStopMarginSeconds = 1;

  /// The quickest plan on [maps] (by [key]) and the quickest with the
  /// fewest stops that can work: from [minStops] stops up, the first stop
  /// count with a plan, then up to [maxExtraStops] more.
  static (_Plan, _Plan)? _bestPlan(_Search search, List<_FuelMapOption> maps, int minStops, double Function(_Plan) key) {
    _Plan? fewest;
    for (var n = minStops.clamp(0, search.totalLaps - 1); n <= search.totalLaps - 1; n++) {
      fewest = search.best(n, maps);
      if (fewest != null) break;
    }
    if (fewest == null) return null;
    var chosen = fewest;
    for (var n = fewest.stops + 1; n <= fewest.stops + maxExtraStops && n <= search.totalLaps - 1; n++) {
      final p = search.best(n, maps);
      if (p != null && key(p) < key(chosen) - extraStopMarginSeconds) chosen = p;
    }
    return (chosen, fewest);
  }

  /// Why each tyre runs where it does.
  static List<String> _tyreNotes(
    _Plan plan,
    List<String> fastestFirst,
    Map<String, DryTyrePace> dryPace,
    Map<String, int> measuredLife,
    int? cap,
    String? mandatory,
    _Search search,
  ) {
    // The mandatory compound, where the plan runs it only because it must.
    final forced = mandatory == null
        ? null
        : [
            for (var i = 0; i < plan.tyres.length; i++)
              if (plan.tyres[i] == mandatory && search.fastestLasting(plan.lengths[i]) != mandatory) i,
          ];
    final forcedOnly = forced != null && forced.isNotEmpty && forced.length == plan.tyres.where((t) => t == mandatory).length;
    bool timed(String c) => dryPace[c]?.hasPace ?? false;

    final notes = <String>[];
    for (final c in fastestFirst) {
      if (forcedOnly && c == mandatory) continue;
      final which = [for (var i = 0; i < plan.tyres.length; i++) if (plan.tyres[i] == c) i + 1];
      if (which.isEmpty) continue;
      final longest = [for (final n in which) plan.lengths[n - 1]].reduce((a, b) => a > b ? a : b);
      final where = which.length == plan.tyres.length ? 'all race' : 'for stint${which.length == 1 ? '' : 's'} ${which.join(', ')}';
      final why = <String>[];
      final faster = fastestFirst.takeWhile((f) => f != c).where((f) => search.lifeOf(f) < longest).toList();
      if (faster.isNotEmpty) {
        why.add(faster.map((f) => '${_shortTyre(f)} last only ${search.lifeOf(f)} laps').join(', '));
      } else if (fastestFirst.first == c) {
        final next = fastestFirst.skip(1).firstOrNull;
        if (next == null) {
          why.add('the only dry tyre allowed');
        } else if (timed(c) && timed(next)) {
          why.add('${((dryPace[next]!.lapMs - dryPace[c]!.lapMs) / 1000).toStringAsFixed(1)}s a lap faster than '
              '${_shortTyre(next)} in your practice laps');
        } else {
          why.add('the fastest tyre allowed (not timed against ${_shortTyre(next)} here yet)');
        }
      } else {
        why.add('the quickest over the race');
      }
      if (measuredLife[c] == null && cap == null) {
        why.add('wear not measured yet -- the ${_shortTyre(c).replaceFirst(RegExp(r's$'), '')} stint test checks they last $longest laps');
      } else {
        why.add('they last about ${search.lifeOf(c)} laps against ${which.length == 1 ? 'a stint of' : 'stints up to'} $longest');
      }
      notes.add('${_shortTyre(c)} $where: ${why.join('; ')}.');
    }
    if (forcedOnly) {
      notes.add('${_shortTyre(mandatory!)} on stint${forced.length == 1 ? '' : 's'} ${[for (final i in forced) i + 1].join(', ')}: '
          'the brief makes them mandatory.');
    }
    return notes;
  }

  /// "Softs all race", "Softs then Hards", with any leaner map.
  static String _describe(_Plan plan) {
    final run = <String>[];
    for (final c in plan.tyres) {
      if (run.isEmpty || run.last != c) run.add(c);
    }
    final tyres = run.length == 1 ? '${_shortTyre(run.single)} all race' : run.map(_shortTyre).join(' then ');
    final lean = [for (var i = 0; i < plan.maps.length; i++) if (plan.maps[i].map > 1) 'Map ${plan.maps[i].map} for stint ${i + 1}'];
    return lean.isEmpty ? tyres : '$tyres (${lean.join(', ')})';
  }

  static String _stops(int n) => '$n stop${n == 1 ? '' : 's'}';

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
    required String Function(int laps) slickFor,
  }) {
    final totalLaps = briefing.totalLaps;

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
        compound = slickFor(last - first + 1);
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
    pitStops.sort((a, b) => a.lap.compareTo(b.lap));

    // The brief's minimum stops: any still owed go halfway through the
    // longest stints (same tyre on again, fresh, with fuel).
    final owed = briefing.mandatoryPitStopCount - pitStops.length;
    if (owed > 0) {
      basis.add('The brief requires ${briefing.mandatoryPitStopCount} stop${briefing.mandatoryPitStopCount == 1 ? '' : 's'}; '
          'the weather needs ${pitStops.length}, so $owed more ${owed == 1 ? 'goes' : 'go'} in the longest stint${owed == 1 ? '' : 's'}.');
    }
    for (var n = 0; n < owed; n++) {
      final starts = [1, for (final p in pitStops) p.lap];
      var best = -1, bestLength = 1;
      for (var k = 0; k < starts.length; k++) {
        // (the last stint can't be split on the last lap)
        final length = (k + 1 < starts.length ? starts[k + 1] : totalLaps) - starts[k];
        if (length > bestLength) {
          best = k;
          bestLength = length;
        }
      }
      if (best < 0) break; // no stint long enough to split
      final lap = starts[best] + bestLength ~/ 2;
      final compound = best == 0 ? (spells.isEmpty ? slickFor(totalLaps) : spells.first.$1) : pitStops[best - 1].tireCompound;
      pitStops.insert(
        best,
        PlannedPitStop(lap: lap, tireCompound: compound, reasoning: 'Mandatory stop (the brief\'s minimum): fresh $compound and fuel.'),
      );
    }

    final startingTire = spells.isEmpty ? slickFor(totalLaps) : spells.first.$1;
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

  /// Each stint's laps, for stops on [stopLaps] in a [totalLaps] race. A
  /// stop on lap N is at the end of lap N (the in-lap): the stint before
  /// it runs to lap N, the next one from lap N + 1 -- as the driver reads
  /// "Lap 4: Box", and as the live fuel target counts it (FuelTarget).
  static List<int> stintLengths(int totalLaps, List<int> stopLaps) => [
    for (var i = 0; i <= stopLaps.length; i++)
      (i < stopLaps.length ? stopLaps[i] : totalLaps) - (i == 0 ? 0 : stopLaps[i - 1]),
  ];
}

/// A fuel map the search may run: its fuel a lap and pace cost (a share
/// of the lap), and whether it's measured here (with the measurement).
class _FuelMapOption {
  final int map;
  final double perLap;
  final double lapTimeLoss;
  final bool measured;
  final FuelMapMeasurement? measurement;
  const _FuelMapOption(this.map, this.perLap, this.lapTimeLoss, {required this.measured, this.measurement});
}

/// One plan: each stint's laps, tyre and fuel map, and its race time in
/// three parts -- in the pits, given up to fuel maps, and on the tyres.
class _Plan {
  final List<int> lengths;
  final List<String> tyres;
  final List<_FuelMapOption> maps;
  final double pitSeconds;
  final double mapSeconds;
  final double tyreSeconds;
  const _Plan(this.lengths, this.tyres, this.maps, {required this.pitSeconds, required this.mapSeconds, required this.tyreSeconds});

  int get stops => lengths.length - 1;

  /// The same stints in tyre-pace order, the slowest first ([slowFirst])
  /// or the fastest (see PitStopCalculator.withTyreOrder).
  _Plan ordered(Map<String, double> pace, {required bool slowFirst}) {
    final order = PitStopCalculator._paceOrder(tyres, pace, slowFirst: slowFirst);
    return _Plan(
      [for (final i in order) lengths[i]],
      [for (final i in order) tyres[i]],
      [for (final i in order) maps[i]],
      pitSeconds: pitSeconds,
      mapSeconds: mapSeconds,
      tyreSeconds: tyreSeconds,
    );
  }

  /// Each stop's lap: the last lap of the stint before it.
  List<int> get stopLaps {
    final laps = <int>[];
    var lap = 0;
    for (final l in lengths.take(lengths.length - 1)) {
      lap += l;
      laps.add(lap);
    }
    return laps;
  }
}

/// The search: for a number of stops, the quickest way to split the race
/// into stints and run each one -- a stint of L laps on the tyre and map
/// that make it quickest, of those that last it -- with the brief's
/// mandatory compound (and any other [required] one) run somewhere. Of
/// plans equally quick, the one with its stops closest to evenly spread
/// (so a plan doesn't jump about); a stint on a mandatory compound run
/// only because it must goes last.
///
/// Mid-race ([first]): the first stint is the one being run -- on the
/// tyres fitted, with the fuel in the tank -- and [totalLaps] the laps left.
class _Search {
  final int totalLaps;

  /// Fastest first.
  final List<String> tyres;
  final Map<String, double> pace;
  final int Function(String) lifeOf;
  final double lap;
  final double pitLoss;
  final String? mandatory;
  final int Function(_FuelMapOption) tankLaps;

  /// Compounds the plan has to run (the mandatory one, unless run already).
  final List<String> required;
  final _FirstStint? first;

  /// The shortest stint the plan may have (not the stint being run,
  /// mid-race) -- so a plan made to run a tyre can't run it for a lap.
  final int minStintLaps;

  _Search({
    required this.totalLaps,
    required this.tyres,
    required this.pace,
    required this.lifeOf,
    required this.lap,
    required this.pitLoss,
    required this.mandatory,
    required this.tankLaps,
    List<String>? required,
    this.first,
    this.minStintLaps = 1,
  }) : required = required ?? [?mandatory];

  _Search copyWith({List<String>? tyres, List<String>? required, int? minStintLaps}) => _Search(
    totalLaps: totalLaps,
    tyres: tyres ?? this.tyres,
    pace: pace,
    lifeOf: lifeOf,
    lap: lap,
    pitLoss: pitLoss,
    mandatory: mandatory,
    tankLaps: tankLaps,
    required: required ?? this.required,
    first: first,
    minStintLaps: minStintLaps ?? this.minStintLaps,
  );

  /// The fastest tyre that lasts [length] laps, if any.
  String? fastestLasting(int length) => tyres.where((c) => lifeOf(c) >= length).firstOrNull;

  static const double _same = 1e-6;

  _Plan? best(int stops, List<_FuelMapOption> maps) {
    final stints = stops + 1;
    if (stints > totalLaps) return null;
    final byMap = [...maps]..sort((a, b) => a.map.compareTo(b.map));

    // The map costing least that lasts [length] laps on [tank].
    _FuelMapOption? mapFor(int length, int Function(_FuelMapOption) tank) => byMap.where((m) => tank(m) >= length).fold<_FuelMapOption?>(
      null,
      (best, m) => best == null || m.lapTimeLoss < best.lapTimeLoss - _same ? m : best,
    );
    _Stint? stint(int length, String tyre, {int? life, int Function(_FuelMapOption)? tank}) {
      if ((life ?? lifeOf(tyre)) < length) return null;
      final map = mapFor(length, tank ?? tankLaps);
      if (map == null) return null;
      return _Stint(length, tyre, map, tyreSeconds: length * pace[tyre]!, mapSeconds: length * lap * map.lapTimeLoss);
    }

    // The quickest ways to run a stint of each length: on the fastest
    // tyre that lasts, and on each compound that has to be run.
    List<_Stint> optionsOf(int length) => [
      if (fastestLasting(length) case final c?) ?stint(length, c),
      for (final c in required)
        if (c != fastestLasting(length)) ?stint(length, c),
    ];
    final options = [for (var l = 0; l <= totalLaps; l++) l == 0 ? const <_Stint>[] : optionsOf(l)];
    final firstOptions = first == null
        ? null
        : [
            for (var l = 0; l <= totalLaps; l++)
              if (l == 0) const <_Stint>[] else [?stint(l, first!.tyre, life: first!.lifeLaps, tank: first!.tankLaps)],
          ];
    int bit(String tyre) {
      final i = required.indexOf(tyre);
      return i < 0 ? 0 : 1 << i;
    }

    // cost[k][t][f]: the quickest first k stints covering t laps, f = the
    // required compounds run (a bit each).
    const inf = double.infinity;
    final masks = 1 << required.length;
    final done = masks - 1;
    final cost = List.generate(stints + 1, (_) => List.generate(totalLaps + 1, (_) => List.filled(masks, inf)));
    final dev = List.generate(stints + 1, (_) => List.generate(totalLaps + 1, (_) => List.filled(masks, 0)));
    final from = List.generate(stints + 1, (_) => List.generate(totalLaps + 1, (_) => List<(int, int, _Stint)?>.filled(masks, null)));
    cost[0][0][0] = 0;
    for (var k = 1; k <= stints; k++) {
      final even = k < stints ? (totalLaps * k / stints).round() : totalLaps;
      for (var t = k; t <= totalLaps - (stints - k); t++) {
        if (k == stints && t != totalLaps) continue;
        for (var prev = k - 1; prev < t; prev++) {
          final length = t - prev;
          if (length < minStintLaps && !(k == 1 && first != null)) continue;
          for (var f = 0; f < masks; f++) {
            final base = cost[k - 1][prev][f];
            if (base == inf) continue;
            for (final s in k == 1 && firstOptions != null ? firstOptions[length] : options[length]) {
              final nf = f | bit(s.tyre);
              final c = base + s.tyreSeconds + s.mapSeconds;
              final d = dev[k - 1][prev][f] + (t - even).abs();
              final cur = cost[k][t][nf];
              if (c < cur - _same || ((c - cur).abs() <= _same && d < dev[k][t][nf])) {
                cost[k][t][nf] = c;
                dev[k][t][nf] = d;
                from[k][t][nf] = (prev, f, s);
              }
            }
          }
        }
      }
    }
    if (cost[stints][totalLaps][done] == inf) return null;

    // Back through the stints.
    final picked = <_Stint>[];
    var t = totalLaps, f = done;
    for (var k = stints; k >= 1; k--) {
      final (prev, pf, s) = from[k][t][f]!;
      picked.insert(0, s);
      t = prev;
      f = pf;
    }
    // A stint on the mandatory compound only because it must be run: to
    // the end of the race (a stint's time doesn't depend on where it
    // runs), so the rest of the race goes as it would without it. (Not
    // the stint being run, mid-race.)
    if (mandatory != null && required.contains(mandatory)) {
      final i = picked.indexWhere((s) => s.tyre == mandatory && fastestLasting(s.length) != mandatory);
      if (i >= (first == null ? 0 : 1) && picked.where((s) => s.tyre == mandatory).length == 1) picked.add(picked.removeAt(i));
    }
    final tyresRun = [for (final s in picked) s.tyre];
    return _Plan(
      [for (final s in picked) s.length],
      tyresRun,
      [for (final s in picked) s.map],
      pitSeconds: stops * pitLoss,
      mapSeconds: picked.fold(0.0, (a, s) => a + s.mapSeconds),
      tyreSeconds: picked.fold(0.0, (a, s) => a + s.tyreSeconds),
    );
  }
}

/// Mid-race, the stint being run: the tyres fitted, the laps they have
/// left, and the laps the fuel in the tank lasts on each map.
class _FirstStint {
  final String tyre;
  final int lifeLaps;
  final int Function(_FuelMapOption) tankLaps;
  const _FirstStint(this.tyre, this.lifeLaps, this.tankLaps);
}

class _Stint {
  final int length;
  final String tyre;
  final _FuelMapOption map;
  final double tyreSeconds;
  final double mapSeconds;
  const _Stint(this.length, this.tyre, this.map, {required this.tyreSeconds, required this.mapSeconds});
}
