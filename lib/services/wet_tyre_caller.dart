import '../models/opponent_pit_stop.dart';
import '../models/practice_lap_record.dart';
import '../models/weather_forecast.dart';
import '../models/weather_radar.dart';
import 'water_pace_model.dart';
import 'water_trend.dart';
import 'wet_pace_table.dart';

/// Box or stay out, for a tyre change.
enum WetVerdict { box, boxAtPlannedStop, stayOut, untested }

/// A tyre-change decision for the weather now (see WetTyreCaller).
class WetTyreDecision {
  final WetVerdict verdict;
  final WeatherTyre current;
  final WeatherTyre target;

  /// The weather the decision is for ("DRY", "R05"...) and the laps the
  /// target tyre would be used for before the weather turns again.
  final String level;
  final int lapsOnTarget;

  /// Measured lap gain of [target] over [current] in [level] (ms; null
  /// if not tested), and what a stop costs.
  final double? gainPerLapMs;
  final double pitLossSeconds;

  /// A stop already planned (for fuel) in the window, where the tyre
  /// change costs next to nothing.
  final int? plannedStopLap;

  /// Rivals who have already fitted [target], with OUR lap at the time.
  final List<OpponentPitStop> rivalsOnTarget;

  /// Water-gauge calls: the reading, and the crossover it was judged
  /// against (measured in testing, or GT7's gauge line).
  final double? waterPercent;
  final double? crossoverPercent;
  final bool crossoverMeasured;

  /// The gauge's trend, percentage points a lap (negative = drying), and
  /// -- for a call made a lap early off the trend -- the water now
  /// ([waterPercent] is then where the trend puts it a lap on, when a
  /// stop made this lap would be done).
  final double? waterPerLap;
  final double? waterNowPercent;

  const WetTyreDecision({
    required this.verdict,
    required this.current,
    required this.target,
    required this.level,
    required this.lapsOnTarget,
    required this.gainPerLapMs,
    required this.pitLossSeconds,
    this.plannedStopLap,
    this.rivalsOnTarget = const [],
    this.waterPercent,
    this.crossoverPercent,
    this.crossoverMeasured = false,
    this.waterPerLap,
    this.waterNowPercent,
  });

  WetTyreDecision withTrend(double perLap, {double? waterNow}) => WetTyreDecision(
    verdict: verdict,
    current: current,
    target: target,
    level: level,
    lapsOnTarget: lapsOnTarget,
    gainPerLapMs: gainPerLapMs,
    pitLossSeconds: pitLossSeconds,
    plannedStopLap: plannedStopLap,
    rivalsOnTarget: rivalsOnTarget,
    waterPercent: waterPercent,
    crossoverPercent: crossoverPercent,
    crossoverMeasured: crossoverMeasured,
    waterPerLap: perLap,
    waterNowPercent: waterNow,
  );

  /// Seconds won (or lost, negative) by switching now, if tested.
  double? get netSeconds => gainPerLapMs == null ? null : gainPerLapMs! * lapsOnTarget / 1000 - pitLossSeconds;

  /// What [target] has to be faster a lap to pay for the stop.
  double get breakEvenPerLapSeconds => pitLossSeconds / lapsOnTarget;
}

/// Boxington's tyre-change calls in a wet race (Race Mode). Each lap it
/// works out, from the weather brief, which tyre the weather calls for
/// now; when that isn't the tyre we're on, whether changing pays: the
/// faster tyre (by wet testing, see WetPaceTable) has to win back the
/// pit stop over the laps until the weather turns again. A stop already
/// planned for fuel in that window makes the change nearly free.
///
/// The track lags the sky -- it stays wet a couple of laps after rain
/// stops, and takes a lap to soak once it starts -- so a call waits
/// that long into a new spell. It also warns a couple of laps before
/// rain is due. Each call is made once per spell. Nothing is called in
/// the opening spell: the start tyre is the driver's choice on the grid
/// (e.g. Inters under R06, rather than Wets and a stop).
///
/// The brief is only a forecast, so the lap times are read too (see
/// readTrack): laps that look like a weather where the other tyre
/// tested faster make a call even when the brief says otherwise.
class WetTyreCaller {
  /// Laps into a drier spell before the track is taken to have dried.
  static const int dryingLagLaps = 2;

  /// Laps into a wetter spell before the track is taken to be wet.
  static const int soakingLagLaps = 1;

  /// How far ahead rain is warned of.
  static const int warnAheadLaps = 2;

  /// Radar rain arriving within this many laps is warned of; once the
  /// radar is clear for this far around, the next rain is a new warning.
  static const double rainWarnLaps = 3;
  static const double rainClearKm = 80;

  /// A drying track is flagged this many laps before it crosses a line.
  static const double dryWarnLaps = 3;

  /// Pirelli's rule of thumb: once slick laps are 110-112% of dry pace
  /// the track is wet enough for intermediates. Used when wet testing
  /// can't place the lap times.
  static const double slicksToIntersPercent = 110;

  /// A live lap within this much of a tested pace is taken to be that
  /// weather (see readTrack).
  static const double matchPercent = 3;

  final Set<String> _called = {};

  /// The tyre last called from the water gauge, until we're on the
  /// tyre the gauge calls for again.
  WeatherTyre? _waterCall;
  WeatherTyre? _practiceCall;

  void reset() {
    _called.clear();
    _waterCall = null;
    _practiceCall = null;
  }

  /// Practice: the gauge says another tyre suits the track -- said as
  /// information (no pit call: there's no race to pay a stop back over),
  /// once each time the gauge and the tyre part ways, so the race calls
  /// can be rehearsed and a drying run spotted. The last lap's average
  /// has to agree, as in a race.
  String? practiceCheck({
    required double water,
    required String currentCompound,
    required List<PracticeLapRecord> laps,
  }) {
    final model = WaterPaceModel.fromLaps(laps);
    final current = WetPaceTable.tyreOf(currentCompound);
    final target = model.tyreFor(water);
    final practice = laps.where((l) => !l.isRaceLap && !l.isPitLap).toList();
    final lastLapWater = practice.isEmpty ? null : practice.last.waterPercent;
    if (target == current || (lastLapWater != null && model.tyreFor(lastLapWater) != target)) {
      if (target == current) _practiceCall = null;
      return null;
    }
    if (_practiceCall == target) return null;
    _practiceCall = target;

    final drier = target.index < current.index;
    final (crossover, measured) = model.crossover(drier ? target : current);
    final gain = model.gainMs(current, target, water);
    return 'Practice, information only -- not a pit call. Water gauge ${water.round()}%, '
        '${drier ? 'below' : 'above'} ${measured ? 'our measured crossover' : "GT7's gauge line"} at ${crossover.round()}%: '
        '${target.label} territory; we are on ${current.label}. '
        '${gain == null ? '' : 'Our laps say ${target.label} is about ${(gain / 1000).abs().toStringAsFixed(1)}s a lap ${gain > 0 ? 'faster' : 'slower'} here. '}'
        '${measured ? '' : 'Laps on both tyres around this water would measure the crossover for our car. '}'
        'Tell the driver in one short sentence.';
  }

  /// The decision for the weather at [currentLap], or null when the
  /// tyre we're on is the one the weather calls for (or it's too soon
  /// into the spell to say).
  static WetTyreDecision? decide({
    required WeatherForecast forecast,
    required int currentLap,
    required int totalLaps,
    required String currentCompound,
    required WetPaceTable pace,
    required double pitLossSeconds,
    List<int> plannedStopLaps = const [],
    List<OpponentPitStop> opponentStops = const [],
  }) {
    final current = WetPaceTable.tyreOf(currentCompound);
    final slot = forecast.slots[forecast.slotAtLap(currentLap, totalLaps) - 1];
    final target = slot.tyre;
    if (target == current) return null;

    final phase = forecast.phases.firstWhere((p) => forecast.slotAtLap(currentLap, totalLaps) <= p.lastSlot);
    final (phaseStart, phaseEnd) = forecast.lapsOfPhase(phase, totalLaps);
    // The opening spell's tyre was chosen on the grid.
    if (phaseStart == 1) return null;
    final drier = target.index < current.index;
    if (currentLap - phaseStart < (drier ? dryingLagLaps : soakingLagLaps)) return null;

    final lapsOnTarget = phaseEnd - currentLap + 1;
    if (lapsOnTarget <= 0) return null;
    final level = WetPaceTable.levelOf(slot);
    final onTarget = pace.pace(level, target), onCurrent = pace.pace(level, current);
    final gain = onTarget == null || onCurrent == null ? null : onCurrent.lapMs - onTarget.lapMs;
    final plannedStop = plannedStopLaps.where((l) => l >= currentLap && l <= phaseEnd).firstOrNull;
    final rivals = [
      for (final s in opponentStops)
        if (s.ourLap >= phaseStart - 1 && _tyreOfLetter(s.tyre) == target) s,
    ];

    final WetVerdict verdict;
    if (plannedStop != null && (gain == null || gain > 0)) {
      verdict = WetVerdict.boxAtPlannedStop;
    } else if (gain == null) {
      verdict = WetVerdict.untested;
    } else {
      verdict = gain * lapsOnTarget / 1000 > pitLossSeconds ? WetVerdict.box : WetVerdict.stayOut;
    }
    return WetTyreDecision(
      verdict: verdict,
      current: current,
      target: target,
      level: level,
      lapsOnTarget: lapsOnTarget,
      gainPerLapMs: gain,
      pitLossSeconds: pitLossSeconds,
      plannedStopLap: plannedStop,
      rivalsOnTarget: rivals,
    );
  }

  /// The decision from GT7's water gauge -- the surface itself, so no
  /// guessing at how far the track lags the sky. The tyre for [water] is
  /// set by the crossovers (measured in wet testing, else GT7's gauge
  /// lines: 33% inters, 66% wets); the last lap's average has to agree,
  /// so a passing shower doesn't make a call. A change pays if the
  /// tested gain at this water wins back the stop before the brief next
  /// changes the weather. In the brief's opening spell (the start tyre
  /// was the driver's choice) only a measured paying switch is called.
  static WetTyreDecision? fromWater({
    required double water,
    double? lastLapWater,
    required WeatherForecast? forecast,
    required int currentLap,
    required int totalLaps,
    required String currentCompound,
    required WaterPaceModel model,
    required double pitLossSeconds,
    List<int> plannedStopLaps = const [],
    List<OpponentPitStop> opponentStops = const [],
  }) {
    final current = WetPaceTable.tyreOf(currentCompound);
    final target = model.tyreFor(water);
    if (target == current) return null;
    if (lastLapWater != null && model.tyreFor(lastLapWater) != target) return null;

    final boundaryTyre = target.index < current.index ? target : current;
    final (crossover, measured) = model.crossover(boundaryTyre);
    final lastLap = forecast == null ? totalLaps : _lastLapFor(forecast, target, currentLap, totalLaps);
    final lapsOnTarget = lastLap - currentLap + 1;
    if (lapsOnTarget <= 0) return null;
    final gain = model.gainMs(current, target, water);
    final plannedStop = plannedStopLaps.where((l) => l >= currentLap && l <= lastLap).firstOrNull;
    final rivals = [
      for (final s in opponentStops)
        if (s.ourLap >= currentLap - 3 && _tyreOfLetter(s.tyre) == target) s,
    ];

    final WetVerdict verdict;
    if (plannedStop != null && (gain == null || gain > 0)) {
      verdict = WetVerdict.boxAtPlannedStop;
    } else if (gain == null) {
      verdict = WetVerdict.untested;
    } else {
      verdict = gain * lapsOnTarget / 1000 > pitLossSeconds ? WetVerdict.box : WetVerdict.stayOut;
    }
    final openingSpell = forecast != null && forecast.lapsOfPhase(forecast.phases.first, totalLaps).$2 >= currentLap;
    if (openingSpell && target.index > current.index && verdict != WetVerdict.box) return null;

    return WetTyreDecision(
      verdict: verdict,
      current: current,
      target: target,
      level: 'water ${water.round()}%',
      lapsOnTarget: lapsOnTarget,
      gainPerLapMs: gain,
      pitLossSeconds: pitLossSeconds,
      plannedStopLap: plannedStop,
      rivalsOnTarget: rivals,
      waterPercent: water,
      crossoverPercent: crossover,
      crossoverMeasured: measured,
    );
  }

  /// What the lap times say, regardless of the brief: the rain cells can
  /// miss the circuit, arrive early or linger. The last two clean race
  /// laps on the current tyre are matched to the wet-testing pace on
  /// that tyre (the weather they look like); if the other candidate
  /// tyre was faster there and wins back the stop before the brief turns
  /// the weather again, that's a call. With no testing to match against,
  /// Pirelli's 110% rule calls slicks to inters.
  static WetTyreDecision? readTrack({
    required WeatherForecast? forecast,
    required int currentLap,
    required int totalLaps,
    required String currentCompound,
    required List<PracticeLapRecord> laps,
    required WetPaceTable pace,
    required double pitLossSeconds,
    List<int> plannedStopLaps = const [],
  }) {
    final recent = _cleanRaceLaps(laps, currentCompound);
    if (recent.length < 2) return null;
    final last2 = recent.sublist(recent.length - 2);
    final lapMs = (last2[0].lapTimeMs + last2[1].lapTimeMs) / 2;
    final current = WetPaceTable.tyreOf(currentCompound);

    // The tested weather these laps look like.
    String? level;
    var nearest = double.infinity;
    for (final l in pace.testedLevels) {
      final p = pace.pace(l, current);
      if (p == null) continue;
      final off = (p.lapMs - lapMs).abs();
      if (off < nearest && off <= p.lapMs * matchPercent / 100) (level, nearest) = (l, off);
    }

    WeatherTyre target;
    double? gain;
    if (level != null) {
      final c = pace.compare(level);
      if (c == null || c.faster == current || c.slower != current) return null;
      target = c.faster;
      gain = c.deltaMs;
    } else {
      // Untested: only the slicks-to-inters rule of thumb.
      final dry = pace.pace('DRY', WeatherTyre.slicks);
      if (current != WeatherTyre.slicks || dry == null) return null;
      if (last2.any((l) => l.lapTimeMs < dry.lapMs * slicksToIntersPercent / 100)) return null;
      level = 'wet (${(lapMs / dry.lapMs * 100).round()}% of dry pace)';
      target = WeatherTyre.inters;
    }

    final lastLap = forecast == null ? totalLaps : _lastLapFor(forecast, target, currentLap, totalLaps);
    final lapsOnTarget = lastLap - currentLap + 1;
    if (lapsOnTarget <= 0) return null;
    final plannedStop = plannedStopLaps.where((l) => l >= currentLap && l <= lastLap).firstOrNull;
    final WetVerdict verdict;
    if (plannedStop != null && (gain == null || gain > 0)) {
      verdict = WetVerdict.boxAtPlannedStop;
    } else if (gain == null) {
      verdict = WetVerdict.untested;
    } else {
      verdict = gain * lapsOnTarget / 1000 > pitLossSeconds ? WetVerdict.box : WetVerdict.stayOut;
    }
    return WetTyreDecision(
      verdict: verdict,
      current: current,
      target: target,
      level: level,
      lapsOnTarget: lapsOnTarget,
      gainPerLapMs: gain,
      pitLossSeconds: pitLossSeconds,
      plannedStopLap: plannedStop,
    );
  }

  /// The last lap [target] is worth running from [currentLap]: until the
  /// brief's next change of weather -- or the one after, if that change
  /// is to [target] (the rain just came early) -- else the race's end.
  static int _lastLapFor(WeatherForecast forecast, WeatherTyre target, int currentLap, int totalLaps) {
    WeatherTyre tyreAt(int lap) => forecast.slots[forecast.slotAtLap(lap, totalLaps) - 1].tyre;
    var briefNow = tyreAt(currentLap);
    for (var lap = currentLap + 1; lap <= totalLaps; lap++) {
      final t = tyreAt(lap);
      if (t == briefNow) continue;
      if (t != target) return lap - 1;
      briefNow = t;
    }
    return totalLaps;
  }

  /// The latest race's laps on [compound] that say something about pace:
  /// not the start lap, not a pit lap or the out-lap after one.
  static List<PracticeLapRecord> _cleanRaceLaps(List<PracticeLapRecord> laps, String compound) {
    final race = laps.where((l) => l.isRaceLap).toList();
    if (race.isEmpty) return const [];
    final latest = race.where((l) => l.raceNumber == race.last.raceNumber).toList();
    return [
      for (var i = 1; i < latest.length; i++)
        if (!latest[i].isPitLap && !latest[i - 1].isPitLap && latest[i].tireCompound == compound) latest[i],
    ];
  }

  /// Rain due within [warnAheadLaps] that calls for a wetter tyre than
  /// [currentCompound]: (lap it's due, the slot), or null.
  static (int, WeatherSlot)? rainAhead({
    required WeatherForecast forecast,
    required int currentLap,
    required int totalLaps,
    required String currentCompound,
  }) {
    final current = WetPaceTable.tyreOf(currentCompound);
    for (final phase in forecast.phases) {
      final (start, _) = forecast.lapsOfPhase(phase, totalLaps);
      if (start <= currentLap || start - currentLap > warnAheadLaps) continue;
      if (phase.tyre.index > current.index) return (start, forecast.slots[phase.firstSlot - 1]);
    }
    return null;
  }

  /// The call to make this lap, as a prompt for Boxington, or null.
  String? check({
    required WeatherForecast? forecast,
    required int currentLap,
    required int totalLaps,
    required String currentCompound,
    required List<PracticeLapRecord> laps,
    required double pitLossSeconds,
    bool pitLossAssumed = false,
    List<int> plannedStopLaps = const [],
    List<OpponentPitStop> opponentStops = const [],
    double? waterPercent,
    double? waterPercentPerMinute,
    double? lapSeconds,
    WeatherRadar? radar,
  }) {
    if (currentLap <= 0 || totalLaps <= 0 || currentLap > totalLaps) return null;
    final stop = '${pitLossSeconds.round()}s${pitLossAssumed ? ' (assumed)' : ''}';

    if (waterPercent != null) {
      // The gauge is the truth about the surface: it replaces the brief's
      // timing and the lap-time read. The brief still warns of rain.
      final race = laps.where((l) => l.isRaceLap && !l.isPitLap).toList();
      final model = WaterPaceModel.fromLaps(laps);
      WetTyreDecision? decideAt(double water, double? lastLapWater) => fromWater(
        water: water,
        lastLapWater: lastLapWater,
        forecast: forecast,
        currentLap: currentLap,
        totalLaps: totalLaps,
        currentCompound: currentCompound,
        model: model,
        pitLossSeconds: pitLossSeconds,
        plannedStopLaps: plannedStopLaps,
        opponentStops: opponentStops,
      );
      // The gauge's trend a lap: where the water will be once a stop made
      // this lap is done.
      final rate = waterPercentPerMinute;
      final perLap = rate == null || lapSeconds == null || rate.abs() < WaterTrend.steadyPercentPerMinute
          ? null
          : rate * lapSeconds / 60;
      final ahead = perLap == null ? null : (waterPercent + perLap).clamp(0.0, 100.0);
      final current = WetPaceTable.tyreOf(currentCompound);

      var decision = decideAt(waterPercent, race.isEmpty ? null : race.last.waterPercent)?.withTrend(perLap ?? 0);
      // The track is heading back the other way: by the time a stop's done
      // the tyre we're on is right again.
      if (decision != null && ahead != null && model.tyreFor(ahead) == current) decision = null;
      // A lap early: the trend crosses the line before a stop could be done.
      if (decision == null && ahead != null) decision = decideAt(ahead, null)?.withTrend(perLap!, waterNow: waterPercent);

      if (decision == null) {
        _waterCall = null; // back on the right tyre (or no call due): the next mismatch is new
      } else if (decision.verdict != WetVerdict.stayOut && _waterCall != decision.target) {
        _waterCall = decision.target;
        return _switchPrompt(decision, stop, _recentLaps(laps));
      }
      final early = _earlyWarning(
        radar: radar,
        water: waterPercent,
        perLap: perLap,
        lapSeconds: lapSeconds,
        current: current,
        model: model,
      );
      if (early != null) return early;
      return forecast == null ? null : _rainWarning(forecast, currentLap, totalLaps, currentCompound);
    }
    if (forecast == null) return null;

    final pace = WetPaceTable.fromLaps(laps);

    final decision = decide(
      forecast: forecast,
      currentLap: currentLap,
      totalLaps: totalLaps,
      currentCompound: currentCompound,
      pace: pace,
      pitLossSeconds: pitLossSeconds,
      plannedStopLaps: plannedStopLaps,
      opponentStops: opponentStops,
    );
    final phase = _phaseOf(forecast, currentLap, totalLaps);
    if (decision != null) {
      if (_called.add('switch:$phase:${decision.target.name}')) {
        return _switchPrompt(decision, stop, _recentLaps(laps));
      }
    }

    // The lap times disagree with the brief (or it's the opening spell).
    final live = readTrack(
      forecast: forecast,
      currentLap: currentLap,
      totalLaps: totalLaps,
      currentCompound: currentCompound,
      laps: laps,
      pace: pace,
      pitLossSeconds: pitLossSeconds,
      plannedStopLaps: plannedStopLaps,
    );
    if (live != null &&
        live.verdict != WetVerdict.stayOut && // the plan stands; nothing to say
        live.target != decision?.target &&
        !_called.contains('switch:$phase:${live.target.name}') &&
        _called.add('live:$phase:${live.target.name}')) {
      return _switchPrompt(live, stop, _recentLaps(laps), fromLapTimes: true);
    }

    return _rainWarning(forecast, currentLap, totalLaps, currentCompound);
  }

  String? _rainWarning(WeatherForecast forecast, int currentLap, int totalLaps, String currentCompound) {
    final rain = rainAhead(forecast: forecast, currentLap: currentLap, totalLaps: totalLaps, currentCompound: currentCompound);
    if (rain != null) {
      final (lap, slot) = rain;
      final key = 'rain:$lap';
      if (_called.add(key)) {
        return 'Weather call. The brief has ${slot.code} ${slot.name} due from about lap $lap '
            '(we are on lap $currentLap, on ${WetPaceTable.tyreOf(currentCompound).label}); it calls for ${slot.tyre.label}. '
            '${slot.number <= 3 ? 'Light rain can miss the circuit or pass quickly. ' : ''}'
            'Warn the driver rain is coming and to watch the radar -- no pit call yet. One short transmission.';
      }
    }
    return null;
  }

  static int _phaseOf(WeatherForecast forecast, int lap, int totalLaps) {
    final slot = forecast.slotAtLap(lap, totalLaps);
    return forecast.phases.indexWhere((p) => slot <= p.lastSlot);
  }

  static String _switchPrompt(WetTyreDecision d, String stop, String recent, {bool fromLapTimes = false}) {
    final gain = d.gainPerLapMs == null ? null : (d.gainPerLapMs! / 1000).toStringAsFixed(1);
    final rivals = d.rivalsOnTarget.isEmpty
        ? ''
        : ' Already on ${d.target.label}: ${d.rivalsOnTarget.map((s) => '${s.driver} (our lap ${s.ourLap})').join(', ')}.';
    final facts =
        '${d.waterPercent != null ? _waterOpening(d) : fromLapTimes ? _lapTimesOpening(d) : 'Tyre call. The brief puts ${d.level} now, which calls for ${d.target.label}; we are on ${d.current.label}. '}'
        '${d.target.label} would run about ${d.lapsOnTarget} laps before the weather turns. A stop costs $stop.$rivals'
        '${recent.isEmpty ? '' : ' Our last laps: $recent.'} ';
    final call = switch (d.verdict) {
          WetVerdict.box =>
            'Testing has ${d.target.label} $gain s a lap faster here: over ${d.lapsOnTarget} laps that wins back the stop '
                'with ${d.netSeconds!.toStringAsFixed(0)}s to spare. Call the driver in for ${d.target.label} this lap.',
          WetVerdict.boxAtPlannedStop =>
            'There is a planned stop on lap ${d.plannedStopLap}: tell the driver to fit ${d.target.label} at that stop -- the change costs next to nothing there.',
          WetVerdict.stayOut =>
            'Testing has ${d.target.label} only $gain s a lap faster here: ${d.lapsOnTarget} laps wins back '
                '${(d.gainPerLapMs! * d.lapsOnTarget / 1000).toStringAsFixed(0)}s, less than the stop. Tell the driver to stay out on ${d.current.label}.',
          WetVerdict.untested when fromLapTimes =>
            'Pirelli\'s rule of thumb is intermediates once slick laps reach 110% of dry pace; ${d.target.label} '
                'needs to be ${d.breakEvenPerLapSeconds.toStringAsFixed(1)}s a lap faster to pay for the stop. Recommend boxing unless the driver says the track is drying.',
          WetVerdict.untested =>
            'Not tested in this weather: ${d.target.label} would need to be ${d.breakEvenPerLapSeconds.toStringAsFixed(1)}s a lap faster to pay for the stop. '
                'Tell the driver that, and to box if the lap times say the ${d.current.label} are clearly losing that much '
                '${d.rivalsOnTarget.isEmpty ? '' : 'or the rivals who switched are clearly quicker'}; otherwise stay out.',
    };
    return '$facts$call One short transmission: say box or stay out, and why in a few words.';
  }

  static String _waterOpening(WetTyreDecision d) {
    final drier = d.target.index < d.current.index;
    final line = d.crossoverMeasured ? 'our measured crossover' : "GT7's gauge line";
    final trend = d.waterPerLap == null || d.waterPerLap == 0
        ? ''
        : ' (${d.waterPerLap! < 0 ? 'falling' : 'rising'} about ${d.waterPerLap!.abs().toStringAsFixed(0)}% a lap)';
    if (d.waterNowPercent != null) {
      return 'Tyre call from the water gauge trend: ${d.waterNowPercent!.round()}% water now$trend, so about '
          '${d.waterPercent!.round()}% by the time a stop this lap is done -- ${drier ? 'below' : 'above'} $line at '
          '${d.crossoverPercent!.round()}%: ${d.target.label} territory; we are on ${d.current.label}. '
          'Boxing this lap means the new tyres go on as the track turns. ';
    }
    return 'Tyre call from the water gauge: ${d.waterPercent!.round()}% water$trend, '
        '${drier ? 'below' : 'above'} $line at ${d.crossoverPercent!.round()}%, so ${d.target.label} territory; '
        'we are on ${d.current.label}. ';
  }

  /// A heads-up before the gauge crosses a line, once each time: rain on
  /// its way (from the radar), or the track drying towards slicks (the
  /// gauge falling with the radar clear over the track). The box call
  /// itself comes off the gauge.
  String? _earlyWarning({
    required WeatherRadar? radar,
    required double water,
    required double? perLap,
    required double? lapSeconds,
    required WeatherTyre current,
    required WaterPaceModel model,
  }) {
    // Rain coming while on slicks (on Inters, more rain is what they're for).
    if (radar != null && current == WeatherTyre.slicks) {
      final (wetLine, _) = model.crossover(current);
      final arrivingLaps = radar.arrivalSeconds == null || lapSeconds == null ? null : radar.arrivalSeconds! / lapSeconds;
      final coming = arrivingLaps != null && arrivingLaps <= rainWarnLaps;
      final overButDry = radar.overTrack && water < wetLine;
      if (radar.clearOverTrack && (radar.nearestRainKm == null || radar.nearestRainKm! > rainClearKm)) _called.remove('radar:rain');
      if ((coming || overButDry) && _called.add('radar:rain')) {
        final where = overButDry
            ? 'shows rain over the track now${radar.building ? ', building' : ''} -- the water gauge (${water.round()}%) will follow'
            : 'has rain ${radar.nearestRainKm!.round()} km out, reaching the track in about '
                  '${arrivingLaps! < 1 ? 'a lap' : '${arrivingLaps.toStringAsFixed(arrivingLaps < 2 ? 1 : 0)} laps'}';
        return 'Weather call from the radar: it $where. We are on ${current.label}. '
            'Warn the driver rain is coming -- the box call will come off the water gauge, no pit call yet. One short transmission.';
      }
    }

    // Drying towards the next tyre down.
    if (current != WeatherTyre.slicks && perLap != null && perLap < 0 && (radar == null || radar.clearOverTrack)) {
      if (radar != null && radar.overTrack) _called.remove('radar:dry');
      final drier = WeatherTyre.values[current.index - 1];
      final (line, measured) = model.crossover(drier);
      final lapsTo = (water - line) / -perLap;
      if (lapsTo > 0.5 && lapsTo <= dryWarnLaps && _called.add('radar:dry')) {
        return 'Weather call: ${radar == null ? 'the water gauge' : "the radar's clear over the track and the water gauge"} is falling about '
            '${(-perLap).toStringAsFixed(0)}% a lap (${water.round()}% now). It reaches '
            '${measured ? 'our measured crossover' : "GT7's gauge line"} at ${line.round()}% in about ${lapsTo.toStringAsFixed(lapsTo < 2 ? 1 : 0)} laps '
            '-- ${drier.label} then, if the dry spell pays for the stop. Tell the driver to get ready, not to box yet. One short transmission.';
      }
    }
    return null;
  }

  static String _lapTimesOpening(WetTyreDecision d) {
    final looks = d.gainPerLapMs == null
        ? 'our laps on ${d.current.label} are ${d.level.replaceFirst('wet (', '').replaceFirst(')', '')}'
        : 'our laps on ${d.current.label} match ${d.level} in testing, where ${d.target.label} is the faster tyre';
    return 'Tyre call from the lap times, not the brief: $looks. '
        'Tell the driver the track looks ${d.target.index > d.current.index ? 'wetter' : 'drier'} than forecast. ';
  }

  /// The latest race laps' times, oldest first, e.g. "1:42.1, 1:40.8".
  static String _recentLaps(List<PracticeLapRecord> laps) {
    final race = laps.where((l) => l.isRaceLap && !l.isPitLap).toList();
    if (race.isEmpty) return '';
    final latestRace = race.last.raceNumber;
    final recent = race.where((l) => l.raceNumber == latestRace).toList();
    return recent
        .sublist(recent.length > 3 ? recent.length - 3 : 0)
        .map((l) => '${l.lapTimeMs ~/ 60000}:${((l.lapTimeMs % 60000) / 1000).toStringAsFixed(1).padLeft(4, '0')}')
        .join(', ');
  }

  static WeatherTyre? _tyreOfLetter(String? letter) => switch (letter) {
    'S' || 'M' || 'H' => WeatherTyre.slicks,
    'IM' => WeatherTyre.inters,
    'W' => WeatherTyre.wets,
    _ => null,
  };
}
