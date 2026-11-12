/// Manually-entered power-curve data for the currently-driven car, used
/// to detect short-shifting/over-revving live from RPM + gear alone.
///
/// GT7's telemetry packet does not expose live horsepower/torque or gear
/// ratios, so there's no way to derive this purely from the UDP stream.
/// Instead the driver reads their car's actual Power/Torque graph off the
/// in-game garage settings screen once, and we hardcode the resulting
/// shift window here. Update these values if you switch cars, or if a
/// BOP update changes the power curve.
///
/// Current config: BMW M6 GT3 Endurance Model '16 (Gr.3, BOP on).
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

  /// BMW M6 GT3 Endurance Model '16, Gr.3 BOP -- the only car currently
  /// driven. Replace/parameterize this if car selection becomes dynamic.
  static const bmwM6Gt3Endurance = PowerBandConfig(
    peakPowerRpm: 6100,
    optimalShiftRpm: 6500,
    overRevRpm: 6900,
  );
}
