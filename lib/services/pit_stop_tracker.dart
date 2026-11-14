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
class PitStopTracker {
  static const double refuelThresholdPercent = 2.0;
  static const double tireChangeJumpPercent = 10.0;
  static const int tireChangeConfirmReadings = 3;

  /// Detection re-arms after the stop only once the car is on a later
  /// lap AND back above pit-lane speed, so a refuel that straddles the
  /// line can't be counted twice.
  static const double rearmSpeedKmh = 100;

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

  PitStopUpdate? update(TelemetryFrame frame) {
    if (!frame.isDriving || frame.currentLap <= 0) return null;

    final lastLap = _lastSeenLap;
    if (lastLap != null && frame.currentLap != lastLap && frame.currentLap != lastLap + 1) {
      // Session restart / jump -- old pit laps no longer line up.
      _pitLaps.clear();
    }
    _lastSeenLap = frame.currentLap;

    int? detected;
    if (!_armed) {
      if (frame.currentLap > _lastStopLap! && frame.speedKmh >= rearmSpeedKmh) {
        _armed = true;
        _minFuelSinceArmed = frame.fuelPercent;
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

    if (averagePercent < last + tireChangeJumpPercent) {
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
    if (!_armed || lap == null || lap <= 0) return null;
    _registerStop(lap);
    return PitStopUpdate(stopDetectedOnLap: lap);
  }

  void _registerStop(int lap) {
    _armed = false;
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
  }
}
