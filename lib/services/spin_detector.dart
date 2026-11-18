import 'dart:math' as math;

import '../models/telemetry_frame.dart';

/// A spin: the car rotated well past the way it was travelling.
class Spin {
  final int lap;

  /// Where it started (world X/Z), for the nearest corner.
  final double x, z;

  /// Speed when it began, km/h.
  final double speedKmh;

  const Spin({required this.lap, required this.x, required this.z, required this.speedKmh});

  /// The synthetic prompt for Boxington's unprompted call; [corner] is
  /// the nearest corner (0 = unknown).
  String toPrompt({int corner = 0}) =>
      'INCIDENT (react now, it just happened): the driver has just SPUN${corner > 0 ? ' at corner $corner' : ''}, '
      'from ${speedKmh.round()} km/h. React as their engineer: calm and quick -- get them going again, watch for '
      'cars coming. If their profile shows spins are a pattern in these conditions or at this corner, give one short '
      'fix (e.g. smoother throttle out of it). Stay within your word limit.';

  @override
  String toString() => 'Spin(lap $lap, ${speedKmh.round()} km/h)';
}

/// Spots spins in the 60 Hz telemetry: the car rotating (yaw rate) far
/// more than its direction of travel is turning (from the velocity). In
/// a normal corner the two match; in a slide they part, and in a spin
/// the difference passes [spinDegrees] within [windowSeconds].
///
/// GT7's sign for the yaw rate against the velocity's heading isn't
/// documented, so it's learnt from the first stretch of normal
/// cornering ([calibrationFrames] frames); until then nothing is called.
class SpinDetector {
  static const double spinDegrees = 100;
  static const double windowSeconds = 3;

  /// A spin has to start at this speed or more (not a three-point turn).
  static const double minSpeedKmh = 25;

  /// Below this the direction of travel is too noisy to use, m/s.
  static const double minGroundSpeedMs = 2;

  /// No second spin called within this of one.
  static const double cooldownSeconds = 6;

  static const int calibrationFrames = 120;

  double _signEvidence = 0;
  int _calibration = 0;
  double? _lastHeading;
  int? _lastPacket;
  double _clock = 0;
  double _cooldownUntil = 0;

  /// (time, slip angle added, speed, x, z) over the window.
  final List<(double, double, double, double, double)> _window = [];

  bool get calibrated => _calibration >= calibrationFrames;

  void reset() {
    _lastHeading = null;
    _lastPacket = null;
    _window.clear();
  }

  /// Feeds a driving frame; returns a spin the moment one is seen.
  Spin? update(TelemetryFrame frame) {
    final packet = frame.packetId;
    final last = _lastPacket;
    var dt = 1 / 60;
    if (last != null && packet > last) dt = ((packet - last) / 60).clamp(1 / 60, 0.2);
    _lastPacket = packet;
    _clock += dt;

    final ground = math.sqrt(frame.velocityX * frame.velocityX + frame.velocityZ * frame.velocityZ);
    if (ground < minGroundSpeedMs) {
      // Too slow to tell which way it's going: what's in the window
      // stays, but nothing is added.
      _lastHeading = null;
      return null;
    }
    final heading = math.atan2(frame.velocityZ, frame.velocityX);
    final previous = _lastHeading;
    _lastHeading = heading;
    if (previous == null) return null;
    final travelRate = _wrap(heading - previous) / dt;

    // Learn the sign from normal cornering: yaw and travel turning together.
    if (frame.speedKmh > 40 && travelRate.abs() > 0.2 && frame.yawRate.abs() > 0.2 && travelRate.abs() < 3) {
      _signEvidence += frame.yawRate * travelRate;
      _calibration++;
    }
    if (!calibrated) return null;
    final sign = _signEvidence >= 0 ? 1.0 : -1.0;

    final slip = (sign * frame.yawRate - travelRate) * dt;
    _window.add((_clock, slip, frame.speedKmh, frame.posX, frame.posZ));
    while (_window.isNotEmpty && _clock - _window.first.$1 > windowSeconds) {
      _window.removeAt(0);
    }
    if (_clock < _cooldownUntil) return null;

    final total = _window.fold<double>(0, (sum, e) => sum + e.$2);
    if (total.abs() * 180 / math.pi < spinDegrees) return null;
    final start = _window.first;
    final fastest = _window.fold<double>(0, (m, e) => e.$3 > m ? e.$3 : m);
    _window.clear();
    _cooldownUntil = _clock + cooldownSeconds;
    if (fastest < minSpeedKmh) return null;
    return Spin(lap: frame.currentLap, x: start.$4, z: start.$5, speedKmh: fastest);
  }

  static double _wrap(double a) {
    while (a > math.pi) {
      a -= 2 * math.pi;
    }
    while (a <= -math.pi) {
      a += 2 * math.pi;
    }
    return a;
  }
}
