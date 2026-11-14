import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/traffic_map.dart';
import 'package:boxbox/services/rejoin_forecaster.dart';

TrafficMap _traffic(List<(double, int)> secondsBehindAndCount, {double lap = 100}) => TrafficMap(
  trackReady: true,
  playerLapProgress: 500,
  lapSeconds: lap,
  cars: [for (final (s, n) in secondsBehindAndCount) TrafficCar(lapProgress: 0, count: n, secondsBehind: s)],
);

void main() {
  test('rejoining next to the car that is one pit-loss behind us', () {
    // 25.5s default loss: the car 26.5s behind ends up 1s behind us.
    final f = RejoinForecaster.forecast(_traffic([(5, 1), (26.5, 1), (60, 1)]))!;
    expect(f.pitLossSeconds, 25.5);
    expect(f.pitLossMeasured, isFalse);
    expect(f.rejoinTraffic, [closeTo(1.0, 1e-9)]);
    expect(f.clearAir, isFalse);
    expect(f.carsPassingWhileStopped, 1);
  });

  test('clear air when nobody is near the rejoin point', () {
    final f = RejoinForecaster.forecast(_traffic([(5, 1), (35, 2)]), measuredPitLossSeconds: 22)!;
    expect(f.pitLossMeasured, isTrue);
    expect(f.rejoinTraffic, isEmpty);
    expect(f.clearAir, isTrue);
  });

  test('cars bunched in one blob count individually', () {
    final f = RejoinForecaster.forecast(_traffic([(20, 3), (24, 1)]), measuredPitLossSeconds: 22)!;
    expect(f.carsPassingWhileStopped, 3);
    expect(f.rejoinTraffic, [closeTo(-2, 1e-9), closeTo(-2, 1e-9), closeTo(-2, 1e-9), closeTo(2, 1e-9)]);
    expect(f.clearAir, isTrue); // nearest is 2s away
  });

  test('a car just ahead of us now ends up a pit-loss further ahead (wraps the short way)', () {
    // 98s behind on a 100s lap = 2s ahead now; after a 25s stop it's 27s
    // ahead -- far from the rejoin, not 73s "behind".
    final f = RejoinForecaster.forecast(_traffic([(98, 1)]), measuredPitLossSeconds: 25)!;
    expect(f.rejoinTraffic, isEmpty);
    expect(f.carsPassingWhileStopped, 0);
  });

  test('no forecast until the map has timed a lap', () {
    expect(RejoinForecaster.forecast(TrafficMap.empty), isNull);
    expect(RejoinForecaster.forecast(const TrafficMap(trackReady: true)), isNull);
  });
}
