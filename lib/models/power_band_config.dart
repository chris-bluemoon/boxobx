/// Manually-entered power-curve data for the currently-driven car, used
/// to detect short-shifting/over-revving live from RPM + gear alone.
///
/// GT7's telemetry packet does not expose live horsepower/torque or gear
/// ratios, so there's no way to derive this purely from the UDP stream.
/// Instead the driver reads their car's actual Power/Torque graph off the
/// in-game garage settings screen once, and we hardcode the resulting
/// shift window per car in [PowerBandConfig.knownCars]; the active one
/// is picked from GT7's car ID at runtime (see [PowerBandConfig.forCar]).
/// Update the values if a BOP update changes a power curve.
///
/// BMW M6 GT3 Endurance Model '16 (Gr.3, BOP on):
/// Peak power ~584 BHP at 6,100 RPM; power drops off steeply above that
/// due to turbo torque fading, well before the car's ~7,100-7,200 RPM
/// mechanical rev limiter -- a classic "must be short-shifted" engine.
class PowerBandConfig {
  /// RPM where this car's peak-power point occurs (from the garage's
  /// Power/Torque graph). Below this, the engine is still building power.
  final double peakPowerRpm;

  /// RPM where you should actually shift for best acceleration -- a bit
  /// past peakPowerRpm so the next gear lands in the meat of the torque
  /// band, rather than shifting right at the peak itself.
  final double optimalShiftRpm;

  /// RPM where power has visibly fallen off a cliff / you're deep into
  /// over-rev territory, regardless of where the mechanical limiter is.
  final double overRevRpm;

  const PowerBandConfig({
    required this.peakPowerRpm,
    required this.optimalShiftRpm,
    required this.overRevRpm,
  });

  /// BMW M6 GT3 Endurance Model '16, Gr.3 BOP (GT7 car ID 3218).
  static const bmwM6Gt3Endurance = PowerBandConfig(
    peakPowerRpm: 6100,
    optimalShiftRpm: 6500,
    overRevRpm: 6900,
  );

  /// Hand-tuned shift windows, keyed by GT7's internal car ID (packet
  /// offset 0x124 -- see TelemetryFrame.carCode). IDs come from the
  /// community car list at github.com/ddm999/gt7info
  /// (_data/db/cars.csv). Add a car here after reading its Power/Torque
  /// graph off the garage screen.
  static const Map<int, PowerBandConfig> knownCars = {
    3218: bmwM6Gt3Endurance,
  };

  /// The shift window to use for the car GT7 says is being driven:
  ///
  /// 1. a hand-tuned entry from [knownCars], if there is one;
  /// 2. otherwise one derived from the car's own rev-indicator range
  ///    (TelemetryFrame.minAlertRpm/maxAlertRpm): over-rev at the point
  ///    the lights flash, shift halfway through the lights. This is an
  ///    approximation -- GT7's lights track the limiter, not the power
  ///    curve, so a turbo car that should be short-shifted will read
  ///    as shifting "early". Good enough until the car is hand-tuned;
  /// 3. otherwise (no car data yet) the BMW config, as before.
  static PowerBandConfig forCar(int carCode, {int minAlertRpm = 0, int maxAlertRpm = 0}) {
    final known = knownCars[carCode];
    if (known != null) return known;
    if (minAlertRpm > 0 && maxAlertRpm > minAlertRpm) {
      return PowerBandConfig(
        peakPowerRpm: minAlertRpm.toDouble(),
        optimalShiftRpm: (minAlertRpm + maxAlertRpm) / 2,
        overRevRpm: maxAlertRpm.toDouble(),
      );
    }
    return bmwM6Gt3Endurance;
  }

  @override
  bool operator ==(Object other) =>
      other is PowerBandConfig &&
      other.peakPowerRpm == peakPowerRpm &&
      other.optimalShiftRpm == optimalShiftRpm &&
      other.overRevRpm == overRevRpm;

  @override
  int get hashCode => Object.hash(peakPowerRpm, optimalShiftRpm, overRevRpm);
}
