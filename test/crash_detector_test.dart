import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/app_mode.dart';
import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/services/crash_detector.dart';

class _Sim {
  final detector = CrashDetector();
  double speed;
  int packetId = 5000;
  final crashes = <Crash>[];

  _Sim(this.speed);

  /// [accel] in km/h per second, 60 frames a second.
  void run(double seconds, {double accel = 0}) {
    for (var i = 0; i < (seconds * 60).round(); i++) {
      speed = math.max(0, speed + accel / 60);
      final crash = detector.update(TelemetryFrame(
        rpm: 6000,
        speedKmh: speed,
        gear: 4,
        posX: 0,
        posY: 0,
        posZ: 0,
        lapDistance: 0,
        trackLength: 0,
        fuelPercent: 50,
        tireTemps: const [80, 80, 80, 80],
        packetId: packetId++,
      ));
      if (crash != null) crashes.add(crash);
    }
  }
}

void main() {
  test('a violent stop is a heavy crash, reported once it settles', () {
    final sim = _Sim(200)..run(2);
    sim.run(0.3, accel: -630); // 200 -> ~10 km/h
    expect(sim.crashes, isEmpty, reason: 'still decelerating');
    sim.run(2);
    final crash = sim.crashes.single;
    expect(crash.speedBeforeKmh, closeTo(200, 1));
    expect(crash.speedAfterKmh, lessThan(15));
    expect(crash.peakDecelG, greaterThan(5));
    expect(crash.toPrompt(), contains('HEAVY CRASH'));
  });

  test('a hit that takes a fast car down to almost nothing is a heavy crash', () {
    final sim = _Sim(120)..run(2);
    sim.run(0.6, accel: -160); // ~4.5 g, 120 -> ~24 km/h
    sim.run(2);
    expect(sim.crashes, hasLength(1));
  });

  test('a knock that costs 40 km/h is not called', () {
    final sim = _Sim(150)..run(2);
    sim.run(0.25, accel: -160);
    sim.run(3);
    expect(sim.crashes, isEmpty);
  });

  test('hard braking at 2.5 g from 280 km/h is not a crash', () {
    final sim = _Sim(280)..run(2);
    sim.run(2.3, accel: -88);
    sim.run(2);
    expect(sim.crashes, isEmpty);
  });

  test('bouncing off the wall twice is one crash', () {
    final sim = _Sim(200)..run(2);
    sim.run(0.25, accel: -600);
    sim.run(1, accel: 60);
    sim.run(0.15, accel: -500);
    sim.run(3);
    expect(sim.crashes, hasLength(1));
  });

  test('a gap in the packets (lost Wi-Fi) does not look like a crash', () {
    final sim = _Sim(200)..run(2);
    sim.packetId += 120;
    sim.speed = 10;
    sim.run(2);
    expect(sim.crashes, isEmpty);
  });

  test('crash and rejoin calls are made in Race Mode only', () {
    expect(AppMode.race.incidentCalls, isTrue);
    expect(AppMode.practice.incidentCalls, isFalse);
    expect(AppMode.timeTrial.incidentCalls, isFalse);
  });
}
