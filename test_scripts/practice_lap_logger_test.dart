// Standalone validation for PracticeLapLogger: builds a per-lap record
// (lap time, tire compound, fuel start/end) every time a lap completes.
//
// Run with: dart run test_scripts/practice_lap_logger_test.dart
import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/services/practice_lap_logger.dart';

void check(String label, bool condition) {
  print('${condition ? "PASS" : "FAIL"} $label');
  if (!condition) throw Exception('Failed: $label');
}

TelemetryFrame frameFor({
  required int lap,
  required int lastLapTimeMs,
  required double fuelPercent,
  double rpm = 6000,
  int gear = 4,
}) =>
    TelemetryFrame(
      rpm: rpm,
      speedKmh: 200,
      gear: gear,
      posX: 0,
      posY: 0,
      posZ: 0,
      lapDistance: 0,
      trackLength: 0,
      fuelPercent: fuelPercent,
      tireTemps: const [90, 90, 90, 90],
      currentLap: lap,
      lastLapTimeMs: lastLapTimeMs,
    );

void main() {
  final logger = PracticeLapLogger()..currentTireCompound = 'Racing Hard';

  // --- No laps logged before any lap completes ---
  logger.update(frameFor(lap: 1, lastLapTimeMs: -1, fuelPercent: 100));
  check('no laps logged before any lap has completed', logger.laps.isEmpty);

  // --- First completed lap logs a record with the selected tire ---
  logger.update(frameFor(lap: 2, lastLapTimeMs: 90000, fuelPercent: 97));
  check('one lap logged after the first completion', logger.laps.length == 1);
  check('lap 1 has the correct lap time', logger.laps.first.lapTimeMs == 90000);
  check('lap 1 is tagged with the currently-selected tire', logger.laps.first.tireCompound == 'Racing Hard');
  check('lap 1 fuel start is the fuel level at lap start', logger.laps.first.fuelPercentAtLapStart == 100);
  check('lap 1 fuel end is the fuel level at lap completion', logger.laps.first.fuelPercentAtLapEnd == 97);
  check('lap 1 fuelConsumedPercent is computed correctly', logger.laps.first.fuelConsumedPercent == 3.0);

  // --- Changing the tire compound mid-session affects subsequent laps only ---
  logger.currentTireCompound = 'Racing Medium';
  logger.update(frameFor(lap: 3, lastLapTimeMs: 91000, fuelPercent: 94));
  check('lap 2 is tagged with the NEW tire, not the old one', logger.laps[1].tireCompound == 'Racing Medium');
  check('lap 1 keeps its original tire tag after the compound changed', logger.laps[0].tireCompound == 'Racing Hard');

  // --- Lap numbering increments correctly ---
  check('lap numbers are sequential starting at 1', logger.laps[0].lapNumber == 1 && logger.laps[1].lapNumber == 2);

  // --- formattedLapTime renders minutes:seconds.millis ---
  check('formattedLapTime renders as M:SS.mmm', logger.laps.first.formattedLapTime == '1:30.000');

  // --- A lap-count jump (new session) keeps already-logged laps ---
  final jumpedLap = frameFor(lap: 1, lastLapTimeMs: -1, fuelPercent: 100);
  logger.update(jumpedLap);
  check('a lap-count jump keeps the already-logged laps', logger.laps.length == 2);
  logger.update(frameFor(lap: 2, lastLapTimeMs: 89000, fuelPercent: 97));
  check('laps from the new session append after the old ones', logger.laps.length == 3 && logger.laps.last.lapNumber == 3);

  // --- seedWithPersistedLaps restores prior laps without losing them on the next update ---
  final seeded = PracticeLapLogger();
  seeded.seedWithPersistedLaps(logger.laps.isEmpty ? [] : logger.laps);
  final preSeedLogger = PracticeLapLogger()..currentTireCompound = 'Racing Soft';
  preSeedLogger.update(frameFor(lap: 1, lastLapTimeMs: -1, fuelPercent: 100));
  preSeedLogger.update(frameFor(lap: 2, lastLapTimeMs: 88000, fuelPercent: 96));
  final restored = PracticeLapLogger();
  restored.seedWithPersistedLaps(preSeedLogger.laps);
  check('seedWithPersistedLaps restores the exact same laps', restored.laps.length == 1);
  restored.update(frameFor(lap: 2, lastLapTimeMs: -1, fuelPercent: 96));
  restored.update(frameFor(lap: 3, lastLapTimeMs: 87000, fuelPercent: 93));
  check('new laps after seeding continue numbering from the seeded count', restored.laps.last.lapNumber == 2);

  // --- Free practice: logging disabled means update() is a total
  // no-op, no laps are recorded or appended to an existing log. ---
  final freePracticeLogger = PracticeLapLogger()..currentTireCompound = 'Racing Hard';
  freePracticeLogger.update(frameFor(lap: 1, lastLapTimeMs: -1, fuelPercent: 100));
  freePracticeLogger.update(frameFor(lap: 2, lastLapTimeMs: 90000, fuelPercent: 97));
  check('logging is enabled by default (existing behavior unchanged)', freePracticeLogger.loggingEnabled);
  check('a lap is logged normally before disabling', freePracticeLogger.laps.length == 1);

  freePracticeLogger.setLoggingEnabled(false);
  check('setLoggingEnabled(false) updates loggingEnabled', !freePracticeLogger.loggingEnabled);
  freePracticeLogger.update(frameFor(lap: 3, lastLapTimeMs: 89000, fuelPercent: 94));
  freePracticeLogger.update(frameFor(lap: 4, lastLapTimeMs: 88000, fuelPercent: 91));
  check('no new laps are recorded while logging is disabled (free practice)', freePracticeLogger.laps.length == 1);

  // --- Re-enabling logging resumes recording without computing a
  // bogus lap-time delta across the gap where logging was off. ---
  freePracticeLogger.setLoggingEnabled(true);
  freePracticeLogger.update(frameFor(lap: 4, lastLapTimeMs: -1, fuelPercent: 91)); // re-establishes baseline
  freePracticeLogger.update(frameFor(lap: 5, lastLapTimeMs: 87500, fuelPercent: 88));
  check('re-enabling logging resumes recording new laps', freePracticeLogger.laps.length == 2);
  check(
    're-enabling logging does not retroactively log laps skipped while disabled',
    freePracticeLogger.laps.last.lapTimeMs == 87500,
  );

  // --- reset() clears everything ---
  restored.reset();
  check('reset() clears the practice log entirely', restored.laps.isEmpty);

  // --- withTireWearPercent attaches a manually-logged wear reading
  // without altering any other field (GT7 has no tire-wear telemetry
  // field, so this is the only way to record it). ---
  final original = preSeedLogger.laps.first;
  final withWear = original.withTireWearPercent(62.0);
  check('withTireWearPercent sets the tire wear reading', withWear.tireWearPercent == 62.0);
  check('withTireWearPercent does not change the lap time', withWear.lapTimeMs == original.lapTimeMs);
  check('withTireWearPercent does not change the tire compound', withWear.tireCompound == original.tireCompound);
  check('the original record is unaffected (immutability)', original.tireWearPercent == null);

  // --- removeLap deletes exactly one lap (by its unique recordedAt
  // timestamp) and renumbers the remainder sequentially. ---
  final deletionLogger = PracticeLapLogger()..currentTireCompound = 'Racing Hard';
  deletionLogger.update(frameFor(lap: 1, lastLapTimeMs: -1, fuelPercent: 100));
  deletionLogger.update(frameFor(lap: 2, lastLapTimeMs: 90000, fuelPercent: 97)); // lap 1
  deletionLogger.update(frameFor(lap: 3, lastLapTimeMs: 89500, fuelPercent: 94)); // lap 2
  deletionLogger.update(frameFor(lap: 4, lastLapTimeMs: 89000, fuelPercent: 91)); // lap 3
  check('3 laps logged before any deletion', deletionLogger.laps.length == 3);

  final middleLapRecordedAt = deletionLogger.laps[1].recordedAt;
  deletionLogger.removeLap(middleLapRecordedAt);
  check('removeLap removes exactly one lap', deletionLogger.laps.length == 2);
  check(
    'the deleted lap (by lap time) is no longer present',
    !deletionLogger.laps.any((l) => l.lapTimeMs == 89500),
  );
  check(
    'the remaining laps are renumbered sequentially with no gaps',
    deletionLogger.laps[0].lapNumber == 1 && deletionLogger.laps[1].lapNumber == 2,
  );
  check(
    'the remaining laps keep their original lap times after renumbering',
    deletionLogger.laps[0].lapTimeMs == 90000 && deletionLogger.laps[1].lapTimeMs == 89000,
  );

  // --- removeLap with an unknown timestamp is a safe no-op ---
  deletionLogger.removeLap(DateTime(1999));
  check('removeLap with an unrecognized timestamp does not remove anything', deletionLogger.laps.length == 2);

  // --- A lap logged after a deletion continues numbering correctly,
  // never colliding with a deleted lap's old number. ---
  deletionLogger.update(frameFor(lap: 4, lastLapTimeMs: -1, fuelPercent: 91));
  deletionLogger.update(frameFor(lap: 5, lastLapTimeMs: 88500, fuelPercent: 88));
  check(
    'a new lap logged after a deletion gets the next sequential number',
    deletionLogger.laps.last.lapNumber == 3,
  );

  // --- Shift quality tracking: short-shifts/good shifts/over-revs are
  // classified per upshift (RPM at the instant before gear increases)
  // against PowerBandConfig.bmwM6Gt3Endurance (optimalShiftRpm=6500,
  // overRevRpm=6900) and tallied into the lap they occurred in. ---
  final shiftLogger = PracticeLapLogger()..currentTireCompound = 'Racing Hard';
  shiftLogger.update(frameFor(lap: 1, lastLapTimeMs: -1, fuelPercent: 100, gear: 2, rpm: 5000));
  // A short-shift: upshift at 5000 RPM, well below optimalShiftRpm (6500).
  shiftLogger.update(frameFor(lap: 1, lastLapTimeMs: -1, fuelPercent: 99, gear: 3, rpm: 5500));
  // A good shift: upshift at 6600 RPM, within the optimal window.
  shiftLogger.update(frameFor(lap: 1, lastLapTimeMs: -1, fuelPercent: 98, gear: 3, rpm: 6600));
  shiftLogger.update(frameFor(lap: 1, lastLapTimeMs: -1, fuelPercent: 97, gear: 4, rpm: 6700));
  // An over-rev: upshift at 7000 RPM, past overRevRpm (6900).
  shiftLogger.update(frameFor(lap: 1, lastLapTimeMs: -1, fuelPercent: 96, gear: 4, rpm: 7000));
  shiftLogger.update(frameFor(lap: 1, lastLapTimeMs: -1, fuelPercent: 95, gear: 5, rpm: 7000));
  // Lap 1 completes.
  shiftLogger.update(frameFor(lap: 2, lastLapTimeMs: 92000, fuelPercent: 90, gear: 5, rpm: 7000));

  check('lap 1 recorded exactly 1 short-shift', shiftLogger.laps.first.shortShiftCount == 1);
  check('lap 1 recorded exactly 1 good shift', shiftLogger.laps.first.goodShiftCount == 1);
  check('lap 1 recorded exactly 1 over-rev', shiftLogger.laps.first.overRevShiftCount == 1);

  // --- Shift counts reset to zero at the next lap boundary, not
  // carried over or accumulated across laps. ---
  // A single clean shift during lap 2.
  shiftLogger.update(frameFor(lap: 2, lastLapTimeMs: -1, fuelPercent: 90, gear: 5, rpm: 6600));
  shiftLogger.update(frameFor(lap: 2, lastLapTimeMs: -1, fuelPercent: 88, gear: 6, rpm: 6700));
  shiftLogger.update(frameFor(lap: 3, lastLapTimeMs: 91000, fuelPercent: 85, gear: 6, rpm: 6700));

  check('lap 2 only counts shifts that happened during lap 2 (1 good shift)', shiftLogger.laps[1].goodShiftCount == 1);
  check('lap 2 has zero short-shifts (none happened during lap 2)', shiftLogger.laps[1].shortShiftCount == 0);
  check('lap 2 has zero over-revs (none happened during lap 2)', shiftLogger.laps[1].overRevShiftCount == 0);

  print('\nAll PracticeLapLogger checks passed.');
}
