import '../models/race_strategy.dart';
import 'pit_call_advisor.dart';
import 'pit_stop_calculator.dart';

enum FuelTargetStatus {
  /// On course to make the target -- with room to spare if [FuelTarget.richerMaps] > 0.
  ok,

  /// Using too much: go [FuelTarget.leanerMaps] maps leaner.
  save,

  /// Even the leanest map won't make it: box early.
  boxEarly,
}

/// The live fuel target in a race: what each lap can use to reach the
/// next planned stop (or the flag, with no stop left) against what the
/// last few laps have used, and the fuel map change that closes the gap
/// (each map's saving from [PitStopCalculator.fuelMapSaving]). Worked
/// out from the fuel at the start of the lap, so it holds steady
/// through the lap and moves on at the line.
class FuelTarget {
  /// The lap the fuel has to last to the end of: the stop lap, or the last lap.
  final int targetLap;
  final bool toFinish;

  /// Laps still to run on this fuel, this one included.
  final int lapsLeft;

  final double needPerLap;
  final double usingPerLap;
  final FuelTargetStatus status;

  /// Map steps leaner needed ([FuelTargetStatus.save]), or richer that
  /// would still make it ([FuelTargetStatus.ok]) -- 0 if none.
  final int leanerMaps;
  final int richerMaps;

  /// When the fuel runs out at this rate ([FuelTargetStatus.boxEarly]).
  final int? emptyLap;

  const FuelTarget({
    required this.targetLap,
    required this.toFinish,
    required this.lapsLeft,
    required this.needPerLap,
    required this.usingPerLap,
    required this.status,
    this.leanerMaps = 0,
    this.richerMaps = 0,
    this.emptyLap,
  });

  /// Fuel (percent) kept back for the run down the pit lane or to the line.
  static const double reservePercent = 1.0;

  /// How much over (+) or under (-) the target, percent a lap.
  double get overPerLap => usingPerLap - needPerLap;

  /// [plannedStops] in order, [stopsMade] so far; [totalLaps] the race's
  /// laps if known; [fuelAtLapStart] the fuel at the start of
  /// [currentLap]; [usingPerLap] the recent laps' average; [planMap] the
  /// map the strategy runs (assumed to be the one the laps were driven on).
  static FuelTarget? of({
    required int currentLap,
    required double? fuelAtLapStart,
    required double? usingPerLap,
    required List<PlannedPitStop> plannedStops,
    required int stopsMade,
    int? totalLaps,
    int planMap = 1,
  }) {
    if (currentLap <= 0 || fuelAtLapStart == null || usingPerLap == null || usingPerLap <= 0) return null;
    PlannedPitStop? next;
    for (final (i, stop) in plannedStops.indexed) {
      if (i < stopsMade || stop.lap < currentLap - PitCallAdvisor.windowLaps) continue;
      next = stop;
      break;
    }
    final int target;
    if (next != null && (totalLaps == null || next.lap < totalLaps)) {
      target = next.lap;
    } else if (totalLaps != null && totalLaps > 0) {
      target = totalLaps;
    } else {
      return null;
    }
    final toFinish = next == null || target != next.lap;
    final lapsLeft = (target - currentLap + 1).clamp(1, 1000);
    final need = (fuelAtLapStart - reservePercent) / lapsLeft;

    final map = planMap.clamp(1, PitStopCalculator.maxFuelMap);
    double relative(int m) => PitStopCalculator.fuelMapFactor(m) / PitStopCalculator.fuelMapFactor(map);

    if (usingPerLap <= need) {
      var richer = 0;
      while (map - richer - 1 >= 1 && usingPerLap * relative(map - richer - 1) <= need) {
        richer++;
      }
      return FuelTarget(
        targetLap: target,
        toFinish: toFinish,
        lapsLeft: lapsLeft,
        needPerLap: need,
        usingPerLap: usingPerLap,
        status: FuelTargetStatus.ok,
        richerMaps: richer,
      );
    }
    for (var leaner = 1; map + leaner <= PitStopCalculator.maxFuelMap; leaner++) {
      if (usingPerLap * relative(map + leaner) <= need) {
        return FuelTarget(
          targetLap: target,
          toFinish: toFinish,
          lapsLeft: lapsLeft,
          needPerLap: need,
          usingPerLap: usingPerLap,
          status: FuelTargetStatus.save,
          leanerMaps: leaner,
        );
      }
    }
    return FuelTarget(
      targetLap: target,
      toFinish: toFinish,
      lapsLeft: lapsLeft,
      needPerLap: need,
      usingPerLap: usingPerLap,
      status: FuelTargetStatus.boxEarly,
      emptyLap: currentLap - 1 + (fuelAtLapStart / usingPerLap).floor(),
    );
  }

  /// The tile, e.g. "OK", "+1 MAP", "BOX L14".
  String get tileValue => switch (status) {
    FuelTargetStatus.ok => 'OK',
    FuelTargetStatus.save => '+$leanerMaps MAP',
    FuelTargetStatus.boxEarly => 'BOX L$emptyLap',
  };

  String get where => toFinish ? 'the flag (lap $targetLap)' : 'the lap $targetLap stop';

  /// For Boxington's live context.
  Map<String, dynamic> toPrompt() => {
    'fuelHasToLastTo': toFinish ? 'finish, lap $targetLap' : 'planned stop, lap $targetLap',
    'lapsLeftOnThisFuel': lapsLeft,
    'fuelNeededPerLapPercent': needPerLap.toStringAsFixed(1),
    'fuelUsingPerLapPercent': usingPerLap.toStringAsFixed(1),
    'fuelAdvice': switch (status) {
      FuelTargetStatus.ok =>
        richerMaps > 0 ? 'fine with room: can run $richerMaps map${richerMaps == 1 ? '' : 's'} richer' : 'on target',
      FuelTargetStatus.save => 'go $leanerMaps map${leanerMaps == 1 ? '' : 's'} leaner (higher fuel map number)',
      FuelTargetStatus.boxEarly => 'cannot make it even on the leanest map: box by lap $emptyLap',
    },
  };

  /// The unprompted radio call when the advice changes.
  String toCallPrompt() {
    final numbers = 'need ${needPerLap.toStringAsFixed(1)}% a lap to reach $where, using ${usingPerLap.toStringAsFixed(1)}%';
    final what = switch (status) {
      FuelTargetStatus.ok => richerMaps > 0
          ? 'fuel is fine with room to spare -- they can go $richerMaps fuel map${richerMaps == 1 ? '' : 's'} richer (a lower map number) and push'
          : 'fuel is back on target -- hold this map',
      FuelTargetStatus.save =>
        'they must save fuel -- go $leanerMaps fuel map${leanerMaps == 1 ? '' : 's'} leaner (a higher map number), short-shift and lift early',
      FuelTargetStatus.boxEarly => "they can't make it on fuel even on the leanest map -- they'll have to box by lap $emptyLap",
    };
    return 'FUEL CALL (unprompted, tell the driver now): $what ($numbers). One short transmission, within your word limit.';
  }
}

/// When Boxington makes an unprompted fuel call: when the advice changes
/// (on target -> save a map, save one -> save two, can't make it...), at
/// most once every [minLapsBetween] laps -- the consumption average
/// takes that long to show a map change -- except a box-early call,
/// which goes at once. Nothing is said while it's simply on target.
class FuelCallAdvisor {
  static const int minLapsBetween = 3;

  String? _lastKey;
  int? _lastCallLap;

  void reset() {
    _lastKey = null;
    _lastCallLap = null;
  }

  static String _key(FuelTarget t) => switch (t.status) {
    FuelTargetStatus.ok => t.richerMaps > 0 ? 'room' : 'ok',
    FuelTargetStatus.save => 'save${t.leanerMaps}',
    FuelTargetStatus.boxEarly => 'box',
  };

  /// The call to make now, if any.
  FuelTarget? check(FuelTarget? target, {required int currentLap}) {
    if (target == null || target.lapsLeft <= 1) return null;
    final key = _key(target);
    final last = _lastKey;
    if (key == last) return null;
    if (last == null && key == 'ok') {
      _lastKey = key; // on target from the start: nothing to say
      return null;
    }
    final since = _lastCallLap == null ? null : currentLap - _lastCallLap!;
    if (key != 'box' && since != null && since < minLapsBetween) return null;
    _lastKey = key;
    _lastCallLap = currentLap;
    return target;
  }
}
