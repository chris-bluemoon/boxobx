import '../models/telemetry_frame.dart';

/// How much grip the car had over one lap, from the wheel speeds in the
/// UDP stream: a wheel turning faster than the car is moving is spinning
/// (wheelspin, or aquaplaning on standing water), one turning slower is
/// locking. All three rise as the track gets wetter, so a lap's figures
/// against the same car's dry laps say how much grip there is -- the
/// first wet-weather signal that needs no reading off the HUD.
class LapGrip {
  /// Share of full-throttle time with a wheel spinning, percent.
  final double wheelspinPercent;

  /// Share of full-throttle time with GT7's TCS flag set, percent.
  /// (Community decoders call the bit "TCS active"; if it turns out to
  /// mean "TCS switched on" it will read ~100% on every lap.)
  final double tcsPercent;

  /// Share of braking time with a wheel locking, percent.
  final double lockupPercent;

  const LapGrip({required this.wheelspinPercent, required this.tcsPercent, required this.lockupPercent});
}

/// Builds a [LapGrip] for each lap from the 60 Hz frames (see
/// PracticeLapLogger, which attaches it to the lap's record).
class GripTracker {
  /// A wheel at least this much faster than the car is spinning.
  static const double spinSlip = 0.10;

  /// A wheel at least this much slower than the car is locking.
  static const double lockSlip = 0.15;

  /// Full throttle / braking, percent pedal.
  static const double fullThrottlePercent = 80;
  static const double brakingPercent = 30;

  /// Below this the slip ratio is too noisy to mean anything.
  static const double minSpeedKmh = 50;

  int _throttleFrames = 0;
  int _spinFrames = 0;
  int _tcsFrames = 0;
  int _brakeFrames = 0;
  int _lockFrames = 0;

  void update(TelemetryFrame frame) {
    if (!frame.isDriving || frame.speedKmh < minSpeedKmh) return;
    final wheels = frame.wheelSpeedsKmh;
    final hasWheels = wheels.length == 4 && wheels.any((w) => w > 0);
    if (frame.throttlePercent >= fullThrottlePercent && frame.brakePercent < 5) {
      _throttleFrames++;
      if (frame.flags & TelemetryFlags.tcs != 0) _tcsFrames++;
      if (hasWheels && _maxSlip(wheels, frame.speedKmh) >= spinSlip) _spinFrames++;
    } else if (frame.brakePercent >= brakingPercent && hasWheels) {
      _brakeFrames++;
      if (_minSlip(wheels, frame.speedKmh) <= -lockSlip) _lockFrames++;
    }
  }

  /// The lap just finished, or null if it had too little driving to
  /// say (e.g. no wheel speeds in the stream). Starts the next lap.
  LapGrip? finishLap() {
    final grip = _throttleFrames < 60 // under a second at full throttle
        ? null
        : LapGrip(
            wheelspinPercent: _percent(_spinFrames, _throttleFrames),
            tcsPercent: _percent(_tcsFrames, _throttleFrames),
            lockupPercent: _brakeFrames == 0 ? 0 : _percent(_lockFrames, _brakeFrames),
          );
    reset();
    return grip;
  }

  void reset() {
    _throttleFrames = _spinFrames = _tcsFrames = _brakeFrames = _lockFrames = 0;
  }

  static double _percent(int n, int of) => double.parse((n / of * 100).toStringAsFixed(1));

  static double _maxSlip(List<double> wheels, double speed) => wheels.fold(-1.0, (m, w) => w / speed - 1 > m ? w / speed - 1 : m);
  static double _minSlip(List<double> wheels, double speed) => wheels.fold(1.0, (m, w) => w / speed - 1 < m ? w / speed - 1 : m);
}
