import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/services/grip_tracker.dart';
import 'package:boxbox/services/practice_lap_logger.dart';

TelemetryFrame _frame({
  double speed = 150,
  List<double>? wheels,
  double throttle = 100,
  double brake = 0,
  int lap = 2,
  int flags = TelemetryFlags.carOnTrack,
  double fuel = 80,
}) => TelemetryFrame(
  rpm: 6000,
  speedKmh: speed,
  gear: 4,
  posX: 0,
  posY: 0,
  posZ: 0,
  lapDistance: 0,
  trackLength: 0,
  fuelPercent: fuel,
  tireTemps: const [80, 80, 80, 80],
  currentLap: lap,
  lastLapTimeMs: 90000,
  throttlePercent: throttle,
  brakePercent: brake,
  flags: flags,
  wheelSpeedsKmh: wheels ?? [speed, speed, speed, speed],
);

void main() {
  test('wheelspin, TCS and lock-ups are shares of throttle and braking time', () {
    final grip = GripTracker();
    for (var i = 0; i < 90; i++) {
      grip.update(_frame()); // hooked up
    }
    for (var i = 0; i < 10; i++) {
      grip.update(_frame(wheels: [150, 150, 170, 168], flags: TelemetryFlags.carOnTrack | TelemetryFlags.tcs)); // rears spinning
    }
    for (var i = 0; i < 40; i++) {
      grip.update(_frame(throttle: 0, brake: 80, speed: 120, wheels: i < 10 ? [90, 120, 120, 120] : null));
    }
    final lap = grip.finishLap()!;
    expect(lap.wheelspinPercent, 10);
    expect(lap.tcsPercent, 10);
    expect(lap.lockupPercent, 25);
    expect(grip.finishLap(), isNull, reason: 'starts again for the next lap');
  });

  test('slow corners, the pits and menus are not counted', () {
    final grip = GripTracker();
    for (var i = 0; i < 100; i++) {
      grip.update(_frame(speed: 30, wheels: [60, 60, 60, 60])); // hairpin exit, under the minimum speed
      grip.update(_frame(flags: TelemetryFlags.carOnTrack | TelemetryFlags.paused, wheels: [300, 300, 300, 300]));
    }
    expect(grip.finishLap(), isNull);
  });

  test('a stream without wheel speeds records no wheelspin or lock-ups', () {
    final grip = GripTracker();
    for (var i = 0; i < 100; i++) {
      grip.update(_frame(wheels: const []));
    }
    final lap = grip.finishLap()!;
    expect(lap.wheelspinPercent, 0);
    expect(lap.lockupPercent, 0);
  });

  test('each logged lap carries its own grip figures', () {
    final logger = PracticeLapLogger();
    logger.update(_frame(lap: 1, fuel: 100));
    for (var i = 0; i < 100; i++) {
      logger.update(_frame(lap: 1, wheels: i < 20 ? [150, 150, 180, 180] : null));
    }
    logger.update(_frame(lap: 2, fuel: 97));
    for (var i = 0; i < 100; i++) {
      logger.update(_frame(lap: 2));
    }
    logger.update(_frame(lap: 3, fuel: 94));
    expect(logger.laps.map((l) => l.wheelspinPercent), [20, 0]);
    expect(logger.laps.first.toMap()['wheelspinPercent'], 20);
  });
}
