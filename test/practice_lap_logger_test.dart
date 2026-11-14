// Covers PracticeLapLogger.currentTireWearPercent: the OCR relay's HUD
// tire-wear reading (set externally by FusedRaceStateManager from
// HudOverlayData, mirroring how currentTireCompound is set from the
// dashboard's manual picker) should be attached to a PracticeLapRecord
// automatically the moment its lap completes -- replacing what used to
// be a manual "log tire wear %" entry on the Practice Log screen.
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/services/practice_lap_logger.dart';

void main() {
  TelemetryFrame frame({required int currentLap, required int lastLapTimeMs, required double fuelPercent}) =>
      TelemetryFrame(
        rpm: 5000,
        speedKmh: 200,
        gear: 4,
        posX: 0,
        posY: 0,
        posZ: 0,
        lapDistance: 0,
        trackLength: 1000,
        fuelPercent: fuelPercent,
        tireTemps: const [80, 80, 80, 80],
        currentLap: currentLap,
        lastLapTimeMs: lastLapTimeMs,
      );

  test('a completed lap is tagged with currentTireWearPercent at the moment it completes', () {
    final logger = PracticeLapLogger();

    // Lap 1 starts.
    logger.update(frame(currentLap: 1, lastLapTimeMs: -1, fuelPercent: 100));

    // The OCR relay reports a wear reading partway through lap 1 --
    // simulates FusedRaceStateManager's HUD-stream listener setting
    // this from a live HudOverlayData update.
    logger.currentTireWearPercent = 87.5;

    // Lap 1 completes, lap 2 starts.
    logger.update(frame(currentLap: 2, lastLapTimeMs: 92000, fuelPercent: 95));

    expect(logger.laps, hasLength(1));
    expect(logger.laps.single.tireWearPercent, 87.5);
  });

  test('tireWearPercent is null on a completed lap if no OCR reading was ever set', () {
    final logger = PracticeLapLogger();

    logger.update(frame(currentLap: 1, lastLapTimeMs: -1, fuelPercent: 100));
    logger.update(frame(currentLap: 2, lastLapTimeMs: 92000, fuelPercent: 95));

    expect(logger.laps.single.tireWearPercent, isNull);
  });

  test('the SAME currentTireWearPercent value is reused for a later lap if never updated again', () {
    final logger = PracticeLapLogger();

    logger.update(frame(currentLap: 1, lastLapTimeMs: -1, fuelPercent: 100));
    logger.currentTireWearPercent = 90.0;
    logger.update(frame(currentLap: 2, lastLapTimeMs: 92000, fuelPercent: 95));
    // No new OCR reading arrives during lap 2 -- the stale 90.0 value
    // simply carries over, same as currentTireCompound would if the
    // driver never changed the dropdown.
    logger.update(frame(currentLap: 3, lastLapTimeMs: 91500, fuelPercent: 90));

    expect(logger.laps, hasLength(2));
    expect(logger.laps[0].tireWearPercent, 90.0);
    expect(logger.laps[1].tireWearPercent, 90.0);
  });

  test('starting a new session (lap counter drops back to 1) keeps previously logged laps', () {
    final logger = PracticeLapLogger();
    // Laps restored from storage, from an earlier session.
    logger.update(frame(currentLap: 1, lastLapTimeMs: -1, fuelPercent: 100));
    logger.update(frame(currentLap: 2, lastLapTimeMs: 92000, fuelPercent: 95));
    logger.update(frame(currentLap: 3, lastLapTimeMs: 91000, fuelPercent: 90));
    final restored = PracticeLapLogger()..seedWithPersistedLaps(logger.laps);
    expect(restored.laps, hasLength(2));

    // Previous run ended on lap 3; a menu (lap 0) frame comes through,
    // then a brand-new session starts back on lap 1.
    restored.update(frame(currentLap: 3, lastLapTimeMs: 91000, fuelPercent: 90));
    restored.update(frame(currentLap: 0, lastLapTimeMs: -1, fuelPercent: 100));
    restored.update(frame(currentLap: 1, lastLapTimeMs: -1, fuelPercent: 100));
    expect(restored.laps, hasLength(2), reason: 'the session boundary must not wipe stored laps');

    restored.update(frame(currentLap: 2, lastLapTimeMs: 90500, fuelPercent: 95));
    expect(restored.laps, hasLength(3));
    expect(restored.laps.last.lapNumber, 3);
    expect(restored.laps.last.lapTimeMs, 90500);
  });
}
