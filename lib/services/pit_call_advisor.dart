import '../models/fused_race_state.dart';
import '../models/race_strategy.dart';
import 'race_lap_estimator.dart';
import 'rejoin_forecaster.dart';

enum PitCallReason { plannedStop, fuel }

enum PitCallAdvice {
  /// A stop is due and the rejoin looks fine.
  boxNow,

  /// A stop is due but we'd rejoin stuck right behind a car; the window
  /// allows one more lap.
  stayOutOneMore,

  /// Last chance: the fuel runs out next lap, or this is the last lap
  /// of the planned stop's window.
  boxNowForced,
}

/// One unprompted pit call for Boxington (see [PitCallAdvisor]).
class PitCall {
  final PitCallReason reason;
  final PitCallAdvice advice;
  final PlannedPitStop? plannedStop;
  final int? fuelEmptyLap;
  final RejoinForecast? forecast;

  /// The car currently behind us, by leaderboard name when we can match
  /// it, and where it ends up relative to us after our stop (positive =
  /// still behind us, negative = it gets ahead). Null if unknown.
  final String? carBehindName;
  final double? carBehindSecondsAfterStop;

  /// In a timed race, the estimated lap count (see RaceLapEstimator).
  final int? timedRaceLaps;

  const PitCall({
    required this.reason,
    required this.advice,
    this.plannedStop,
    this.fuelEmptyLap,
    this.forecast,
    this.carBehindName,
    this.carBehindSecondsAfterStop,
    this.timedRaceLaps,
  });

  /// Synthetic prompt for VoiceEngine.speakProactively. The decision is
  /// made here, deterministically; Boxington only phrases it.
  String toPrompt() {
    final why = switch (reason) {
      PitCallReason.plannedStop =>
        'our planned pit stop is lap ${plannedStop!.lap}${plannedStop!.tireCompound.isNotEmpty ? ' (fit ${plannedStop!.tireCompound})' : ''}',
      PitCallReason.fuel => 'fuel runs out on lap $fuelEmptyLap',
    };
    final call = switch (advice) {
      PitCallAdvice.boxNow => 'BOX THIS LAP',
      PitCallAdvice.boxNowForced => 'BOX THIS LAP, no more laps in hand',
      PitCallAdvice.stayOutOneMore => 'STAY OUT ONE MORE LAP, then box',
    };

    final details = <String>[];
    final who = carBehindName ?? 'the car behind';
    final after = carBehindSecondsAfterStop;
    if (after != null) {
      details.add(
        after >= 0
            ? 'boxing now we come out ahead of $who (${after.toStringAsFixed(1)}s behind us after the stop)'
            : 'boxing now $who gets past and we come out ${(-after).toStringAsFixed(1)}s behind them',
      );
    }
    final f = forecast;
    if (f != null) {
      if (f.clearAir) {
        details.add('rejoin in clear air');
      } else if (f.rejoinTraffic.isNotEmpty) {
        final nearest = f.rejoinTraffic.first;
        details.add(
          nearest >= 0
              ? 'rejoin with a car ${nearest.toStringAsFixed(1)}s behind us'
              : 'rejoin ${(-nearest).toStringAsFixed(1)}s behind a car',
        );
      }
    }

    if (timedRaceLaps != null) details.add('timed race, about $timedRaceLaps laps in total at our pace');

    return 'Pit call -- $why. Recommendation: $call.'
        '${details.isEmpty ? '' : ' ${details.join('; ')}.'}'
        ' Tell the driver in one short transmission.';
  }
}

/// The Race Mode PIT LAP tile: the next stop to make.
class NextPitLap {
  final int lap;

  /// The fuel runs out (before the finish) ahead of the next planned
  /// stop, or there's no planned stop left.
  final bool forFuel;
  final PlannedPitStop? plannedStop;

  const NextPitLap({required this.lap, this.forFuel = false, this.plannedStop});

  /// The next stop: the strategy's next stop not yet made (one per stop
  /// made so far, skipping any left [PitCallAdvisor.windowLaps] behind),
  /// moved earlier to when the fuel runs out if that's sooner. Null when
  /// no stop is needed: no planned stop left and the fuel lasts the race
  /// (or, without the race length, until the fuel prediction says so).
  static NextPitLap? of(FusedRaceState state, {required List<PlannedPitStop> plannedStops, required int stopsMade}) {
    final lap = state.telemetry.currentLap;
    PlannedPitStop? planned;
    for (final (i, stop) in plannedStops.indexed) {
      if (i < stopsMade || stop.lap < lap - PitCallAdvisor.windowLaps) continue;
      planned = stop;
      break;
    }
    final total = state.raceLaps?.fuelSafeTotal ?? (state.telemetry.totalLaps > 0 ? state.telemetry.totalLaps : null);
    final prediction = state.fuelPrediction;
    var empty = prediction.hasEnoughData ? prediction.predictedEmptyLap : null;
    if (empty != null && total != null && empty > total) empty = null; // makes the finish
    if (empty != null && (planned == null || empty < planned.lap)) return NextPitLap(lap: empty, forFuel: true);
    return planned == null ? null : NextPitLap(lap: planned.lap, plannedStop: planned);
  }
}

/// Decides when Boxington should make an unprompted pit call, and what
/// to recommend.
///
/// When: only while a stop is actually on the cards --
///   * within [windowLaps] laps of a stop in the saved strategy that we
///     haven't already made, or
///   * when fuel runs out within [windowLaps] laps (and before the
///     finish -- a prediction past the last lap needs no stop).
/// At most once per lap, timed for when the pit entry is still
/// [callBeforePitMin]-[callBeforePitMax] of a lap ahead so there's time
/// to act. If the pit's position on the map isn't known yet, the call
/// comes as soon as the lap starts instead.
///
/// What: box now, unless we'd rejoin stuck right behind a car and the
/// window still allows one more lap.
class PitCallAdvisor {
  static const int windowLaps = 2;

  /// Fraction of the lap (0-1000 scale) before the pit entry in which
  /// the call is made.
  static const double callBeforePitMin = 100;
  static const double callBeforePitMax = 350;

  /// Rejoining within this many seconds behind a car counts as stuck
  /// behind it.
  static const double stuckBehindSeconds = 1.5;

  /// The map's nearest car behind and the leaderboard's gap must agree
  /// within this to put the leaderboard name on it.
  static const double nameMatchSeconds = 1.5;

  int? _lastCalledLap;

  void reset() => _lastCalledLap = null;

  /// [pitLapsThisSession]: GT7 laps on which we've already stopped
  /// (PitStopTracker.pitLaps).
  PitCall? check(
    FusedRaceState state, {
    required List<PlannedPitStop> plannedStops,
    required Set<int> pitLapsThisSession,
  }) {
    final lap = state.telemetry.currentLap;
    // GT7's lap count, or the estimate in a timed race.
    final raceLaps =
        state.raceLaps ?? (state.telemetry.totalLaps > 0 ? RaceLaps(total: state.telemetry.totalLaps) : null);
    final totalLaps = raceLaps?.total ?? -1;
    if (state.sessionPhase == SessionPhase.paused || state.sessionPhase == SessionPhase.offTrack) return null;
    if (state.hud.playerInPit || lap <= 0 || totalLaps <= 0 || lap >= totalLaps) return null;
    if (_lastCalledLap == lap) return null;

    final planned = _duePlannedStop(lap, plannedStops, pitLapsThisSession);
    final fuelEmpty = _fuelEmptyLapIfDue(state, lap, raceLaps!.fuelSafeTotal);
    if (planned == null && fuelEmpty == null) return null;
    if (!_isCallPoint(state)) return null;

    final forced = (fuelEmpty != null && fuelEmpty - lap <= 1) || (planned != null && lap >= planned.lap + windowLaps);
    final forecast = state.rejoinForecast;
    final stuck = forecast != null && forecast.rejoinTraffic.any((s) => s < 0 && s >= -stuckBehindSeconds);
    final advice = forced
        ? PitCallAdvice.boxNowForced
        : stuck
        ? PitCallAdvice.stayOutOneMore
        : PitCallAdvice.boxNow;

    final (behindName, behindAfter) = _carBehind(state);
    _lastCalledLap = lap;
    return PitCall(
      reason: planned != null ? PitCallReason.plannedStop : PitCallReason.fuel,
      advice: advice,
      plannedStop: planned,
      fuelEmptyLap: fuelEmpty,
      forecast: forecast,
      carBehindName: behindName,
      carBehindSecondsAfterStop: behindAfter,
      timedRaceLaps: raceLaps.estimated ? raceLaps.total : null,
    );
  }

  static PlannedPitStop? _duePlannedStop(int lap, List<PlannedPitStop> stops, Set<int> pitLaps) {
    for (final stop in stops) {
      if ((lap - stop.lap).abs() > windowLaps) continue;
      final alreadyStopped = pitLaps.any((l) => (l - stop.lap).abs() <= windowLaps);
      if (!alreadyStopped) return stop;
    }
    return null;
  }

  static int? _fuelEmptyLapIfDue(FusedRaceState state, int lap, int totalLaps) {
    final prediction = state.fuelPrediction;
    final empty = prediction.predictedEmptyLap;
    if (!prediction.hasEnoughData || empty == null) return null;
    if (empty > totalLaps) return null; // makes the finish -- no stop needed
    return empty - lap <= windowLaps ? empty : null;
  }

  static bool _isCallPoint(FusedRaceState state) {
    final pit = state.pitLapProgress ?? state.startFinishLapProgress;
    final us = state.hud.traffic.playerLapProgress;
    if (pit == null || us == null) return true; // pit position unknown: call at once
    final toPit = (pit - us) % 1000;
    return toPit >= callBeforePitMin && toPit <= callBeforePitMax;
  }

  /// The car behind us and where it ends up after our stop. Prefers the
  /// map (it sees every car); names it from the leaderboard when the
  /// leaderboard's gap agrees, or when the leaderboard shows no gap.
  static (String?, double?) _carBehind(FusedRaceState state) {
    final forecast = state.rejoinForecast;
    final traffic = state.hud.traffic;
    final name = state.hud.driverBehind;
    final leaderboardGap = state.hud.gapBehindSeconds;

    double? mapGap;
    for (final car in traffic.cars) {
      final s = traffic.relativeSeconds(car);
      if (s != null && s > 0 && (mapGap == null || s < mapGap)) mapGap = s;
    }

    final pitLoss = forecast?.pitLossSeconds ?? RejoinForecaster.defaultPitLossSeconds;
    final gap = mapGap ?? leaderboardGap;
    if (gap == null) return (null, null);
    final nameFits = name != null && (leaderboardGap == null || (leaderboardGap - gap).abs() <= nameMatchSeconds);
    return (nameFits ? name : null, gap - pitLoss);
  }
}
