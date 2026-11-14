import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/services/pit_stop_tracker.dart';

TelemetryFrame _frame({
  required int lap,
  required double fuel,
  int lastLapTimeMs = -1,
  double speedKmh = 200,
  int flags = TelemetryFlags.carOnTrack,
}) =>
    TelemetryFrame(
      rpm: 6000,
      speedKmh: speedKmh,
      gear: 4,
      posX: 0,
      posY: 0,
      posZ: 0,
      lapDistance: 0,
      trackLength: 0,
      fuelPercent: fuel,
      tireTemps: const [80, 80, 80, 80],
      currentLap: lap,
      lastLapTimeMs: lastLapTimeMs,
      flags: flags,
    );

/// Drives laps 1..[upToLap] at a steady 90s with 3%/lap burn, starting
/// from 100%. Returns the fuel level at the start of [upToLap].
double _driveCleanLaps(PitStopTracker tracker, int upToLap) {
  var fuel = 100.0;
  tracker.update(_frame(lap: 1, fuel: fuel));
  for (var lap = 2; lap <= upToLap; lap++) {
    fuel -= 3;
    // Lap 1 (standing start) is slower; it must be excluded from the reference.
    tracker.update(_frame(lap: lap, fuel: fuel, lastLapTimeMs: lap == 2 ? 95000 : 90000));
  }
  return fuel;
}

void main() {
  test('normal fuel burn never registers a stop', () {
    final tracker = PitStopTracker();
    _driveCleanLaps(tracker, 8);
    expect(tracker.pitLaps, isEmpty);
  });

  test('a refuel registers a stop once, even if it straddles the line', () {
    final tracker = PitStopTracker();
    var fuel = _driveCleanLaps(tracker, 6);

    final updates = <PitStopUpdate?>[];
    // In the pit box on lap 6: fuel rises in steps.
    for (var i = 0; i < 5; i++) {
      fuel += 1.5;
      updates.add(tracker.update(_frame(lap: 6, fuel: fuel, speedKmh: 0)));
    }
    // Still refuelling after crossing the line into lap 7, at pit speed.
    for (var i = 0; i < 4; i++) {
      fuel += 1.5;
      updates.add(tracker.update(_frame(lap: 7, fuel: fuel, lastLapTimeMs: 115000, speedKmh: 0)));
    }

    final detections = updates.where((u) => u?.stopDetectedOnLap != null).toList();
    expect(detections, hasLength(1));
    expect(detections.single!.stopDetectedOnLap, 6);
    expect(tracker.pitLaps, {6, 7});
  });

  test('a fuel rise while paused or in a menu is ignored', () {
    final tracker = PitStopTracker();
    _driveCleanLaps(tracker, 4);
    expect(tracker.update(_frame(lap: 4, fuel: 100, flags: TelemetryFlags.carOnTrack | TelemetryFlags.paused)), isNull);
    expect(tracker.update(_frame(lap: 4, fuel: 100, flags: 0)), isNull);
    expect(tracker.pitLaps, isEmpty);
  });

  test('a held tyre-wear jump reports a tyre change and registers a tyre-only stop', () {
    final tracker = PitStopTracker();
    _driveCleanLaps(tracker, 5);
    expect(tracker.reportTireWear(62), isNull);
    expect(tracker.reportTireWear(61), isNull);
    expect(tracker.reportTireWear(100), isNull);
    expect(tracker.reportTireWear(100), isNull);
    final update = tracker.reportTireWear(100);
    expect(update?.tiresChanged, isTrue);
    expect(update?.stopDetectedOnLap, 5);
    expect(tracker.pitLaps, {5, 6});
  });

  test('a single misread wear spike is not a tyre change', () {
    final tracker = PitStopTracker();
    _driveCleanLaps(tracker, 3);
    tracker.reportTireWear(70);
    expect(tracker.reportTireWear(100), isNull);
    expect(tracker.reportTireWear(69), isNull);
    expect(tracker.reportTireWear(100), isNull);
    expect(tracker.reportTireWear(100), isNull);
    expect(tracker.pitLaps, isEmpty);
  });

  test('a tyre change during a refuel stop does not register a second stop', () {
    final tracker = PitStopTracker();
    var fuel = _driveCleanLaps(tracker, 5);
    tracker.reportTireWear(55);
    fuel += 20;
    expect(tracker.update(_frame(lap: 5, fuel: fuel, speedKmh: 0))?.stopDetectedOnLap, 5);
    tracker.reportTireWear(100);
    tracker.reportTireWear(100);
    final update = tracker.reportTireWear(100);
    expect(update?.tiresChanged, isTrue);
    expect(update?.stopDetectedOnLap, isNull);
  });
}
