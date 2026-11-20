import '../models/telemetry_frame.dart';

/// What [PitStopTracker] noticed on a given update. Any combination of
/// fields can be set; an update with nothing to report returns null.
class PitStopUpdate {
  /// GT7 lap number a newly detected stop happened on.
  final int? stopDetectedOnLap;

  /// True when the HUD tyre-wear reading jumped back up (fresh tyres).
  final bool tiresChanged;

  const PitStopUpdate({this.stopDetectedOnLap, this.tiresChanged = false});
}

/// Detects pit stops (for pit-lap exclusion, new stints and the tyre
/// wear reset) from data GT7 already provides. It doesn't time them:
/// the pit stop time is entered from GT7's own on-screen figure (see
/// RaceBriefing.pitStopTimeSeconds).
///
/// * Refuel: fuel percent rising [refuelThresholdPercent] or more above
///   its lowest point since the last stop. Fuel only ever goes down on
///   track, so a sustained rise means the car is being refuelled.
/// * Tyre change: the laptop relay's HUD tyre-wear average (remaining
///   grip, 100 = new) jumping up by [tireChangeJumpPercent] or more, held
///   for [tireChangeConfirmReadings] readings so one misread can't fake
///   a stop. This also catches tyre-only stops with no refuel.
/// * Our own "P" marker on the leaderboard (see [reportPlayerInPit]).
///
/// The HUD signals are OCR and can be misread, so a tyre change or a "P"
/// only counts when the car really stopped (or dropped out of view, as it
/// does in GT7's pit-stop cutscene) on this lap or the one before -- see
/// [stoppedRecently]. A fresh set also has to read nearly new
/// ([freshTyresPercent]). A refuel can't be misread: fuel only rises in
/// the pit box.
class PitStopTracker {
  static const double refuelThresholdPercent = 2.0;
  static const double tireChangeJumpPercent = 10.0;
  static const int tireChangeConfirmReadings = 3;

  /// Detection re-arms after the stop only once the car is two laps on
  /// (past the in-lap and the out-lap) AND back above pit-lane speed. One
  /// stop gives signals over both laps -- the "P" from pit entry, the box
  /// after the line, the new tyres read on the way out -- and each used
  /// to count as another stop.
  static const double rearmSpeedKmh = 100;
  static const int rearmAfterLaps = 2;

  /// Slower than this, the car is standing still (the pit box).
  static const double stoppedSpeedKmh = 5;

  /// A tyre change has to read at least this (remaining grip): new tyres.
  static const double freshTyresPercent = 85;

  int? _stoppedOnLap;

  /// The car stood still, or was out of view, this lap or the last --
  /// as it is at every pit stop. Without it the HUD's "P" or a jump in
  /// the tyre reading is taken to be a misread.
  bool get stoppedRecently {
    final stopped = _stoppedOnLap;
    final lap = _lastSeenLap;
    return stopped != null && lap != null && lap - stopped <= 1;
  }

  /// GT7 isn't showing the car on track mid-session (the pit-stop
  /// cutscene; see FusedRaceStateManager).
  void noteOutOfView() {
    final lap = _lastSeenLap;
    if (lap != null && lap > 0) _stoppedOnLap = lap;
  }

  /// A stop has been registered and the car hasn't left it behind yet
  /// (see [rearmAfterLaps]).
  bool get inStop => !_armed;

  /// How many stops have been registered this session.
  int get stopCount => _stopCount;
  int _stopCount = 0;

  final Set<int> _pitLaps = {};
  int? _lastSeenLap;

  bool _armed = true;
  int? _lastStopLap;
  double? _minFuelSinceArmed;

  double? _lastTireWear;
  int _tireJumpReadings = 0;

  /// GT7 lap numbers affected by a detected stop (the stop lap and the
  /// one after) -- excluded from degradation/fuel averages.
  Set<int> get pitLaps => Set.unmodifiable(_pitLaps);

  /// The lap each stop this session was made on, in order.
  List<int> get stopLaps => List.unmodifiable(_stopLaps);
  final List<int> _stopLaps = [];

  /// [driving]: whether the car is being driven, if the caller knows
  /// better than GT7's flags -- in a replay GT7 says the car is never on
  /// track (see FusedRaceStateManager, which only trusts the flags once
  /// it has seen them set).
  PitStopUpdate? update(TelemetryFrame frame, {bool? driving}) {
    if (!(driving ?? frame.isDriving) || frame.currentLap <= 0) return null;

    final lastLap = _lastSeenLap;
    if (lastLap != null && frame.currentLap != lastLap && frame.currentLap != lastLap + 1) {
      // Session restart / jump -- old pit laps no longer line up.
      _pitLaps.clear();
    }
    _lastSeenLap = frame.currentLap;
    if (frame.speedKmh < stoppedSpeedKmh) _stoppedOnLap = frame.currentLap;

    int? detected;
    if (!_armed) {
      if (frame.currentLap >= _lastStopLap! + rearmAfterLaps && frame.speedKmh >= rearmSpeedKmh) {
        _armed = true;
        _minFuelSinceArmed = frame.fuelPercent;
        // The standstill in the box belongs to the stop just made: the
        // next stop needs a standstill of its own.
        _stoppedOnLap = null;
        _tireJumpReadings = 0;
      }
    } else {
      final min = _minFuelSinceArmed;
      if (min == null || frame.fuelPercent < min) {
        _minFuelSinceArmed = frame.fuelPercent;
      } else if (frame.fuelPercent >= min + refuelThresholdPercent) {
        detected = frame.currentLap;
        _registerStop(frame.currentLap);
      }
    }

    if (detected == null) return null;
    return PitStopUpdate(stopDetectedOnLap: detected);
  }

  /// Feeds the HUD's average remaining-grip percent (only call with a
  /// real reading -- not when the widget wasn't visible).
  PitStopUpdate? reportTireWear(double averagePercent) {
    final last = _lastTireWear;
    if (last == null) {
      _lastTireWear = averagePercent;
      return null;
    }

    // New tyres are often only read on the way out, after the stop was
    // registered: still that stop's tyre change.
    final atStop = stoppedRecently || inStop;
    if (averagePercent < last + tireChangeJumpPercent || averagePercent < freshTyresPercent || !atStop) {
      _tireJumpReadings = 0;
      _lastTireWear = averagePercent;
      return null;
    }

    _tireJumpReadings++;
    if (_tireJumpReadings < tireChangeConfirmReadings) return null;

    _tireJumpReadings = 0;
    _lastTireWear = averagePercent;

    // Usually the same stop a refuel already registered; only a
    // tyre-only stop registers a new one here.
    final lap = _lastSeenLap;
    int? detected;
    if (_armed && lap != null && lap > 0) {
      detected = lap;
      _registerStop(lap);
    }
    return PitStopUpdate(stopDetectedOnLap: detected, tiresChanged: true);
  }

  /// Our own leaderboard row is showing GT7's "P" marker -- the most
  /// direct signal there is. Registers a stop on the current lap unless
  /// one is already registered (e.g. the refuel was spotted first).
  PitStopUpdate? reportPlayerInPit() {
    final lap = _lastSeenLap;
    if (!_armed || lap == null || lap <= 0 || !stoppedRecently) return null;
    _registerStop(lap);
    return PitStopUpdate(stopDetectedOnLap: lap);
  }

  void _registerStop(int lap) {
    _armed = false;
    _stopCount++;
    _stopLaps.add(lap);
    _lastStopLap = lap;
    _pitLaps
      ..add(lap)
      ..add(lap + 1);
  }

  /// Full reset for a new session.
  void reset() {
    _pitLaps.clear();
    _lastSeenLap = null;
    _armed = true;
    _lastStopLap = null;
    _minFuelSinceArmed = null;
    _lastTireWear = null;
    _tireJumpReadings = 0;
    _stoppedOnLap = null;
    _stopCount = 0;
    _stopLaps.clear();
  }
}
