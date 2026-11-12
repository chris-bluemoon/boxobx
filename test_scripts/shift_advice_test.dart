// Standalone validation for ShiftAdvice: the RPM-vs-power-band
// classifier that drives the new "SHIFT" dashboard card (replacing the
// raw GEAR digit, which just duplicated what GT7's own HUD already
// shows). Config is the manually-entered BMW M6 GT3 Endurance power
// curve (see PowerBandConfig).
//
// Run with: dart run test_scripts/shift_advice_test.dart
import 'package:boxbox/models/shift_advice.dart';
import 'package:boxbox/models/power_band_config.dart';

void check(String label, bool condition) {
  print('${condition ? "PASS" : "FAIL"} $label');
  if (!condition) throw Exception('Failed: $label');
}

void main() {
  const config = PowerBandConfig.bmwM6Gt3Endurance;

  check(
    'low RPM (below peak power) classifies as building',
    ShiftAdvice.classify(4000, config: config).zone == ShiftZone.building,
  );

  check(
    'RPM just below optimal shift point still classifies as building',
    ShiftAdvice.classify(config.optimalShiftRpm - 1, config: config).zone == ShiftZone.building,
  );

  check(
    'RPM at optimal shift point classifies as shiftNow',
    ShiftAdvice.classify(config.optimalShiftRpm, config: config).zone == ShiftZone.shiftNow,
  );

  check(
    'RPM between optimal shift and over-rev classifies as shiftNow',
    ShiftAdvice.classify((config.optimalShiftRpm + config.overRevRpm) / 2, config: config).zone ==
        ShiftZone.shiftNow,
  );

  check(
    'RPM at over-rev threshold classifies as overRev',
    ShiftAdvice.classify(config.overRevRpm, config: config).zone == ShiftZone.overRev,
  );

  check(
    'RPM well past over-rev threshold (near mechanical limiter) classifies as overRev',
    ShiftAdvice.classify(7100, config: config).zone == ShiftZone.overRev,
  );

  check(
    'zero/idle RPM classifies as building, not a crash',
    ShiftAdvice.classify(0, config: config).zone == ShiftZone.building,
  );

  print('All ShiftAdvice checks passed.');
}
