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
    tracker.update(_frame(lap: 5, fuel: 88, speedKmh: 0)); // in the box
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

  test('without stopping, a wear jump or a "P" is a misread, not a stop', () {
    final tracker = PitStopTracker();
    _driveCleanLaps(tracker, 5);
    tracker.reportTireWear(30); // misread low
    for (var i = 0; i < 4; i++) {
      expect(tracker.reportTireWear(75), isNull);
    }
    expect(tracker.reportPlayerInPit(), isNull);
    expect(tracker.pitLaps, isEmpty);
    expect(tracker.stopCount, 0);
  });

  test('stopped, but the "new" tyres read worn: not a tyre change', () {
    final tracker = PitStopTracker();
    _driveCleanLaps(tracker, 5);
    tracker.update(_frame(lap: 5, fuel: 88, speedKmh: 0));
    tracker.reportTireWear(30);
    for (var i = 0; i < 4; i++) {
      expect(tracker.reportTireWear(70), isNull);
    }
  });

  test('out of view (the pit-stop cutscene) counts as stopped', () {
    final tracker = PitStopTracker();
    _driveCleanLaps(tracker, 5);
    expect(tracker.reportPlayerInPit(), isNull);
    tracker.noteOutOfView();
    expect(tracker.reportPlayerInPit()?.stopDetectedOnLap, 5);
    expect(tracker.stopCount, 1);
  });

  test('one stop gives signals over the in-lap, the box and the out-lap: still one stop', () {
    // Race 11 at the Nurburgring: "P" at pit entry on lap 8, the box
    // after the line on lap 9, new tyres read on the way out, and the
    // "P" still showing at 100+ km/h -- it used to count three stops.
    final tracker = PitStopTracker();
    var fuel = _driveCleanLaps(tracker, 8);
    tracker.reportTireWear(33);
    tracker.noteOutOfView(); // pit-entry cutscene
    final stops = <int>[];
    void note(PitStopUpdate? u) {
      if (u?.stopDetectedOnLap case final lap?) stops.add(lap);
    }

    note(tracker.reportPlayerInPit());
    note(tracker.update(_frame(lap: 9, fuel: fuel, lastLapTimeMs: 96700, speedKmh: 60)));
    for (var i = 0; i < 10; i++) {
      fuel += 3;
      note(tracker.update(_frame(lap: 9, fuel: fuel, speedKmh: 0)));
      note(tracker.reportPlayerInPit());
    }
    note(tracker.update(_frame(lap: 9, fuel: fuel, speedKmh: 120)));
    note(tracker.reportPlayerInPit());
    var tyresChanged = 0;
    for (var i = 0; i < 4; i++) {
      final u = tracker.reportTireWear(100);
      note(u);
      if (u?.tiresChanged ?? false) tyresChanged++;
    }
    note(tracker.update(_frame(lap: 10, fuel: fuel - 3, lastLapTimeMs: 122800, speedKmh: 200)));
    note(tracker.reportPlayerInPit());
    for (var i = 0; i < 4; i++) {
      note(tracker.reportTireWear(99));
    }
    note(tracker.update(_frame(lap: 11, fuel: fuel - 6, lastLapTimeMs: 94300, speedKmh: 200)));
    note(tracker.reportPlayerInPit());

    expect(stops, [8]);
    expect(tracker.stopCount, 1);
    expect(tracker.pitLaps, {8, 9});
    expect(tyresChanged, 1, reason: 'the new tyres, read after the stop was registered');

    // The second stop, much later, still counts.
    for (var lap = 12; lap <= 23; lap++) {
      tracker.update(_frame(lap: lap, fuel: 50.0 - lap, lastLapTimeMs: 91000, speedKmh: 200));
    }
    tracker.update(_frame(lap: 23, fuel: 27, speedKmh: 0));
    expect(tracker.reportPlayerInPit()?.stopDetectedOnLap, 23);
    expect(tracker.stopCount, 2);
  });
}
