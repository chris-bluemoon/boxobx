// Standalone validation for ShiftHistoryTracker: the upshift-detection
// and rolling-window classification logic that drives the new "GEAR"
// dashboard card's shift-habit dots and verdict (replacing the earlier
// single live shift-now gauge).
//
// Run with: dart run test_scripts/shift_history_tracker_test.dart
import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/models/power_band_config.dart';
import 'package:boxbox/models/shift_event.dart';
import 'package:boxbox/services/shift_history_tracker.dart';

void check(String label, bool condition) {
  print('${condition ? "PASS" : "FAIL"} $label');
  if (!condition) throw Exception('Failed: $label');
}

TelemetryFrame frameWith({required int gear, required double rpm}) {
  return TelemetryFrame(
    rpm: rpm,
    speedKmh: 200,
    gear: gear,
    posX: 0,
    posY: 0,
    posZ: 0,
    lapDistance: 0,
    trackLength: 0,
    fuelPercent: 50,
    tireTemps: const [90, 90, 90, 90],
    currentLap: 1,
    totalLaps: 20,
  );
}

void main() {
  const config = PowerBandConfig.bmwM6Gt3Endurance;

  // --- No shifts yet ---
  final tracker = ShiftHistoryTracker(config: config);
  tracker.update(frameWith(gear: 1, rpm: 4000));
  check('no shifts recorded from a single frame', tracker.recentShifts.isEmpty);

  // --- A single upshift at a "good" RPM is recorded correctly ---
  // The RPM recorded for the shift is from the frame *before* the gear
  // count increased (the RPM the driver actually shifted at) -- so to
  // produce a shift recorded at optimalShiftRpm, that must be the RPM
  // on the pre-shift frame, not the post-shift one.
  final tracker1b = ShiftHistoryTracker(config: config);
  tracker1b.update(frameWith(gear: 1, rpm: config.optimalShiftRpm));
  tracker1b.update(frameWith(gear: 2, rpm: 3000));
  check('upshift detected and recorded', tracker1b.recentShifts.length == 1);
  check(
    'recorded RPM is the RPM just before the shift',
    tracker1b.recentShifts.first.rpmAtShift == config.optimalShiftRpm,
  );
  check('classified as good', tracker1b.recentShifts.first.timing == ShiftTiming.good);

  // --- Downshifts are ignored entirely ---
  tracker1b.update(frameWith(gear: 1, rpm: 5000));
  check('downshift does not get recorded as a shift event', tracker1b.recentShifts.length == 1);

  // --- Neutral transitions don't get misread as upshifts ---
  final tracker2 = ShiftHistoryTracker(config: config);
  tracker2.update(frameWith(gear: 3, rpm: 5000));
  tracker2.update(frameWith(gear: 0, rpm: 1000)); // clutch in / neutral
  tracker2.update(frameWith(gear: 4, rpm: 3000)); // re-engaged into 4th
  check(
    'transition through neutral does not record a spurious shift event',
    tracker2.recentShifts.isEmpty,
  );

  // --- Early (short-shift) and late (over-rev) classification ---
  // The RPM recorded for shift N is the RPM from the frame immediately
  // before the gear-increase frame that triggers recording it -- so to
  // land an early-classified first shift and a late-classified second
  // shift, the "early"/"late" RPM values need to be on the frame
  // *before* each respective gear bump.
  final tracker3 = ShiftHistoryTracker(config: config);
  tracker3.update(frameWith(gear: 1, rpm: config.optimalShiftRpm - 500)); // will be shift 1's RPM
  tracker3.update(frameWith(gear: 2, rpm: config.overRevRpm + 200)); // triggers shift 1, will be shift 2's RPM
  tracker3.update(frameWith(gear: 3, rpm: 3000)); // triggers shift 2
  check('under-threshold shift classified as early', tracker3.recentShifts[0].timing == ShiftTiming.early);
  check('over-threshold shift classified as late', tracker3.recentShifts[1].timing == ShiftTiming.late);

  // --- Rolling window caps at historyWindow (5), dropping oldest first ---
  final tracker4 = ShiftHistoryTracker(config: config);
  var gear = 1;
  tracker4.update(frameWith(gear: gear, rpm: 4000));
  for (var i = 0; i < 7; i++) {
    gear += 1;
    tracker4.update(frameWith(gear: gear, rpm: config.optimalShiftRpm));
  }
  check(
    'history caps at the configured window size',
    tracker4.recentShifts.length == ShiftHistoryTracker.historyWindow,
  );

  // --- Reset clears everything ---
  tracker4.reset();
  check('reset clears recorded shift history', tracker4.recentShifts.isEmpty);
  tracker4.update(frameWith(gear: 1, rpm: 4000));
  tracker4.update(frameWith(gear: 2, rpm: config.optimalShiftRpm));
  check('tracker resumes recording normally after reset', tracker4.recentShifts.length == 1);

  print('\nAll ShiftHistoryTracker checks passed.');
}
