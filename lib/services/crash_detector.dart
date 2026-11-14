import 'dart:math' as math;

import '../models/telemetry_frame.dart';

/// A serious crash, reported once the car has stopped decelerating.
class Crash {
  /// Speed just before the crash, and once it had settled, km/h.
  final double speedBeforeKmh;
  final double speedAfterKmh;

  /// Hardest deceleration seen, in g.
  final double peakDecelG;

  const Crash({required this.speedBeforeKmh, required this.speedAfterKmh, required this.peakDecelG});

  /// The synthetic prompt for Boxington's unprompted call.
  String toPrompt() =>
      'INCIDENT (react now, it just happened): the driver has just had a HEAVY CRASH: '
      '${speedBeforeKmh.round()} km/h down to ${speedAfterKmh.round()} km/h, peaking at ${peakDecelG.toStringAsFixed(1)} g. '
      'React instantly as their engineer, shaken and urgent -- ask if they are OK and if the car still drives. '
      'You cannot see the damage, so never claim any. This is exactly when swearing is warranted. '
      'Stay within your word limit.';

  @override
  String toString() => 'Crash($speedBeforeKmh -> $speedAfterKmh km/h, ${peakDecelG}g)';
}

/// Spots serious crashes in the 60 Hz telemetry: decelerations no
/// brakes can produce. Race cars brake at up to roughly 2.5 g, so
///
/// * 5 g or more over a quarter of a second is a heavy crash, and
/// * 3.5 g or more (a hit) that takes the car from 80+ km/h down to
///   almost nothing is one too.
///
/// Lesser knocks, slides and lock-ups aren't called. The thresholds are
/// physics-based estimates, not yet tuned on real crashes.
class CrashDetector {
  static const double hitDecelG = 3.5;
  static const double heavyCrashDecelG = 5.0;
  static const double decelWindowS = 0.25;
  static const double heavyCrashFromKmh = 80;
  static const double heavyCrashToKmh = 25;

  /// The crash is reported once no hard deceleration has been seen for
  /// this long.
  static const double settleS = 0.6;

  /// A second crash within this time is the same accident.
  static const double cooldownS = 8;

  double _t = 0;
  int? _lastPacketId;
  final List<(double, double)> _speedHistory = []; // (t, km/h)

  // The hit being gathered.
  bool _hit = false;
  bool _heavy = false;
  double _hitStart = 0;
  double _lastHardDecel = 0;
  double _speedBefore = 0;
  double _peakDecelG = 0;

  double _lastReported = -1e9;

  /// Feeds one driving frame; returns a crash once it has settled.
  Crash? update(TelemetryFrame frame) {
    if (!_advanceClock(frame)) return null;
    final speed = frame.speedKmh;
    _speedHistory.add((_t, speed));
    while (_t - _speedHistory.first.$1 > 1.5) {
      _speedHistory.removeAt(0);
    }

    final decelG = _recentDecelG(speed);
    if (decelG != null && decelG >= hitDecelG) {
      if (!_hit) {
        _hit = true;
        _hitStart = _t;
        _speedBefore = _speedHistory.fold(0.0, (m, s) => math.max(m, s.$2));
      }
      _lastHardDecel = _t;
      _peakDecelG = math.max(_peakDecelG, decelG);
      if (decelG >= heavyCrashDecelG) _heavy = true;
    }
    if (!_hit) return null;
    if (_speedBefore >= heavyCrashFromKmh && speed <= heavyCrashToKmh) _heavy = true;
    if (_t - _lastHardDecel < settleS && _t - _hitStart < 4) return null;

    final crash = _heavy && _t - _lastReported >= cooldownS
        ? Crash(speedBeforeKmh: _speedBefore, speedAfterKmh: speed, peakDecelG: _peakDecelG)
        : null;
    if (crash != null) _lastReported = _t;
    _clearHit();
    return crash;
  }

  /// Deceleration over roughly the last [decelWindowS], in g.
  double? _recentDecelG(double speed) {
    (double, double)? then;
    for (final sample in _speedHistory) {
      if (_t - sample.$1 >= decelWindowS) then = sample;
    }
    if (then == null) return null;
    return (then.$2 - speed) / 3.6 / (_t - then.$1) / 9.81;
  }

  /// Advances the clock from GT7's packet counter (1/60 s each). False
  /// after a gap (lost Wi-Fi, pause): a speed jump across a gap isn't a
  /// deceleration, so tracking restarts.
  bool _advanceClock(TelemetryFrame frame) {
    final id = frame.packetId;
    final last = _lastPacketId;
    _lastPacketId = id > 0 ? id : null;
    if (id <= 0) {
      _t += 1 / 60;
      return true;
    }
    if (last == null) return false;
    final delta = id - last;
    if (delta <= 0 || delta > 12) {
      _speedHistory.clear();
      _clearHit();
      return false;
    }
    _t += delta / 60;
    return true;
  }

  void _clearHit() {
    _hit = false;
    _heavy = false;
    _peakDecelG = 0;
    _speedBefore = 0;
  }

  /// Pause or session end.
  void reset() {
    _speedHistory.clear();
    _lastPacketId = null;
    _clearHit();
    _lastReported = -1e9;
  }
}
