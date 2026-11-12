import 'power_band_config.dart';

/// Live classification of the current RPM against the configured car's
/// power band (see PowerBandConfig), so the dashboard can tell the
/// driver to shift at the point of peak acceleration rather than
/// waiting for GT7's own mechanical rev-limiter shift light -- which,
/// for cars like the M6 GT3, fires well past where power has already
/// dropped off.
enum ShiftZone {
  /// Below the power band -- still building power, no action needed.
  building,

  /// Inside the optimal shift window -- shift up now for best
  /// acceleration.
  shiftNow,

  /// Held well past the optimal point -- losing acceleration every
  /// extra RPM, regardless of whether the mechanical limiter has
  /// actually been hit yet.
  overRev,
}

class ShiftAdvice {
  final ShiftZone zone;

  const ShiftAdvice(this.zone);

  factory ShiftAdvice.classify(double rpm, {PowerBandConfig config = PowerBandConfig.bmwM6Gt3Endurance}) {
    if (rpm >= config.overRevRpm) {
      return const ShiftAdvice(ShiftZone.overRev);
    }
    if (rpm >= config.optimalShiftRpm) {
      return const ShiftAdvice(ShiftZone.shiftNow);
    }
    return const ShiftAdvice(ShiftZone.building);
  }
}
