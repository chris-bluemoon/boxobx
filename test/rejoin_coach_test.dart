import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/traffic_map.dart';
import 'package:boxbox/services/rejoin_coach.dart';

TrafficMap _map(List<double?> arrivals) => TrafficMap(
      trackReady: true,
      playerLapProgress: 500,
      lapSeconds: 90,
      cars: [for (final s in arrivals) TrafficCar(lapProgress: 400, secondsToReach: s)],
    );

class _Drive {
  final coach = RejoinCoach();
  var now = DateTime(2026, 11, 14, 12);
  final calls = <(double, RejoinCall)>[];
  double t = 0;

  /// Feeds updates 5 times a second for [seconds].
  void run(double seconds, {required double speed, TrafficMap Function(double t)? map, bool inPit = false}) {
    for (var i = 0; i < (seconds * 5).round(); i++) {
      final call = coach.update(
        speedKmh: speed,
        inPitLane: inPit,
        traffic: map?.call(t) ?? _map([]),
        now: now,
      );
      if (call != null) calls.add((t, call));
      now = now.add(const Duration(milliseconds: 200));
      t += 0.2;
    }
  }

  List<RejoinCall> get words => [for (final c in calls) c.$2];
}

void main() {
  test('stopped with a car coming: wait (not a stream of them)... go once it has passed', () {
    final d = _Drive()..run(5, speed: 150);
    final stopAt = d.t;
    // A car 4.5 s away when we stop; it passes us (and drops off the
    // "behind" list) 4.5 s later.
    TrafficMap map(double t) {
      final eta = 4.5 - (t - stopAt);
      return _map(eta > 0 ? [eta, 40] : [40]);
    }

    d.run(10, speed: 5, map: map);
    final waits = d.words.where((w) => w == RejoinCall.wait).length;
    expect(waits, inInclusiveRange(1, 2));
    expect(d.words.last, RejoinCall.go);
    expect(d.words.where((w) => w == RejoinCall.go), hasLength(1));
    // No wait after the go.
    expect(d.words.indexOf(RejoinCall.go), d.words.length - 1);
    // Waits are spaced out, not every update.
    final waitTimes = [for (final c in d.calls) if (c.$2 == RejoinCall.wait) c.$1];
    for (var i = 1; i < waitTimes.length; i++) {
      expect(waitTimes[i] - waitTimes[i - 1], greaterThanOrEqualTo(RejoinCoach.waitRepeatS - 1e-6));
    }
  });

  test('a go is not taken back the moment a car crosses the clear line', () {
    final d = _Drive()..run(5, speed: 150);
    final stopAt = d.t;
    // 7 s away: clear, go. Driver sits there; at 3 s away: wait.
    d.run(6, speed: 0, map: (t) => _map([7 - (t - stopAt)]));
    expect(d.words.first, RejoinCall.go);
    final firstWait = d.calls.firstWhere((c) => c.$2 == RejoinCall.wait).$1 - stopAt;
    expect(firstWait, greaterThanOrEqualTo(3.9));
  });

  test('stopped with nobody near: go straight away', () {
    final d = _Drive()..run(5, speed: 150);
    d.run(3, speed: 0, map: (_) => _map([30, 60]));
    expect(d.words, [RejoinCall.go]);
  });

  test('stands down once moving again, and a later car is not called', () {
    final d = _Drive()..run(5, speed: 150);
    d.run(2, speed: 0, map: (_) => _map([30]));
    d.run(2, speed: 50, map: (_) => _map([2]));
    expect(d.words, [RejoinCall.go]);
    expect(d.coach.active, isFalse);
  });

  test('a second car arriving before we have moved: wait again, then go again', () {
    final d = _Drive()..run(5, speed: 150);
    d.run(2, speed: 0, map: (_) => _map([30]));
    d.run(2, speed: 0, map: (_) => _map([2]));
    d.run(2, speed: 0, map: (_) => _map([30]));
    expect(d.words.first, RejoinCall.go);
    expect(d.words, contains(RejoinCall.wait));
    expect(d.words.last, RejoinCall.go);
  });

  test('a single phantom car on the map says nothing', () {
    final d = _Drive()..run(5, speed: 150);
    var n = 0;
    // One map read shows a car 2 s away; every other read is clear.
    d.run(3, speed: 0, map: (_) => _map([n++ == 6 ? 2 : 30]));
    expect(d.words, [RejoinCall.go]);
  });

  test('a single missed read of a close car is not a go', () {
    final d = _Drive()..run(5, speed: 150);
    var n = 0;
    d.run(3, speed: 0, map: (_) => _map([n++ == 8 ? 30 : 2]));
    expect(d.words, isNot(contains(RejoinCall.go)));
  });

  test('nothing after the chequered flag', () {
    final d = _Drive()..run(5, speed: 150);
    for (var i = 0; i < 20; i++) {
      expect(d.coach.update(speedKmh: 5, inPitLane: false, traffic: _map([2]), now: d.now, raceOver: true), isNull);
      d.now = d.now.add(const Duration(milliseconds: 200));
    }
  });

  test('not on the grid before the start, nor in the pit lane', () {
    final grid = _Drive()..run(5, speed: 0, map: (_) => _map([1]));
    expect(grid.words, isEmpty);

    final pit = _Drive()..run(5, speed: 150);
    pit.run(5, speed: 0, inPit: true, map: (_) => _map([1]));
    expect(pit.words, isEmpty);
  });

  test('a slow corner is not a stop', () {
    final d = _Drive()..run(5, speed: 150);
    d.run(0.6, speed: 20, map: (_) => _map([1]));
    d.run(2, speed: 100);
    expect(d.words, isEmpty);
  });

  test('says nothing when the map cannot time the traffic', () {
    final d = _Drive()..run(5, speed: 150);
    d.run(3, speed: 0, map: (_) => _map([null]));
    d.run(3, speed: 0, map: (_) => TrafficMap.empty);
    expect(d.words, isEmpty);
  });

  test('a new session starts from the grid again', () {
    final d = _Drive()..run(5, speed: 150);
    d.coach.reset();
    d.run(3, speed: 0, map: (_) => _map([1]));
    expect(d.words, isEmpty);
  });

  group('TrafficMap.nextArrivalSeconds', () {
    test('the soonest car within the horizon', () {
      expect(_map([9, 3.5, 40]).nextArrivalSeconds(), 3.5);
    });
    test('infinity when nobody is close', () {
      expect(_map([40, 70]).nextArrivalSeconds(), double.infinity);
      expect(_map([]).nextArrivalSeconds(), double.infinity);
    });
    test('null when the map is not ready or not timed', () {
      expect(TrafficMap.empty.nextArrivalSeconds(), isNull);
      expect(_map([null, null]).nextArrivalSeconds(), isNull);
    });
    test('reads secondsToReach from the relay', () {
      final map = TrafficMap.fromJson({
        'trackReady': true,
        'playerLapProgress': 10,
        'lapSeconds': 90,
        'cars': [
          {'lapProgress': 5, 'secondsBehind': 12, 'secondsToReach': 2.5},
        ],
      });
      expect(map.nextArrivalSeconds(), 2.5);
    });
  });
}
