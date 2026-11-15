import '../models/traffic_map.dart';

/// One word from the rejoin call.
enum RejoinCall {
  /// A car is about to come past: stay put.
  wait,

  /// Clear behind: rejoin now.
  go,
}

/// "Wait... wait... wait... GO": after a spin, an off or a crash leaves
/// the car stopped or crawling on track, watches the course map for cars
/// arriving from behind and says when it's safe to rejoin without
/// getting in anyone's way.
///
/// It takes over once the car has been at racing speed and then drops
/// below [slowKmh] for [slowForS] outside the pit lane. "Wait" repeats
/// every [waitRepeatS] while the next car is less than [clearSeconds]
/// away; once the gap opens up (or the car has gone past), "Go" (and
/// back to "wait" only if the driver hesitates until a car is within
/// [lateWaitSeconds]). It stands down once the car is moving again
/// after the go, or back up to [rejoinedKmh].
///
/// Arrival times come from the course map (TrafficCar.secondsToReach),
/// which is only read about 5 times a second, so [clearSeconds] keeps a
/// margin. With no map, it says nothing.
///
/// Kept to as few words as do the job: a car has to read close on
/// [confirmReads] map updates in a row before a "wait" (and clear on as
/// many before a "go"), so one phantom or missed blob on the map says
/// nothing; and "wait" repeats only every [waitRepeatS]. Nothing after
/// the chequered flag (slowing down on the in-lap isn't an incident).
class RejoinCoach {
  static const double atSpeedKmh = 80;
  static const double slowKmh = 25;
  static const double slowForS = 0.8;
  static const double movingAgainKmh = 35;
  static const double rejoinedKmh = 70;
  static const double clearSeconds = 5;

  /// Once "go" has been said, it only turns back into "wait" (the driver
  /// hesitated) when a car is closer than this -- not the moment one
  /// crosses [clearSeconds], which would contradict the go a second
  /// after it was given.
  static const double lateWaitSeconds = 3;
  static const double waitRepeatS = 4;

  /// Map updates in a row a reading has to hold for before it's said.
  static const int confirmReads = 2;

  bool _beenAtSpeed = false;
  DateTime? _slowSince;
  bool _active = false;
  DateTime? _lastWait;
  bool _saidGo = false;

  /// The last course map seen, and how many map updates in a row have
  /// read a car close / the way clear.
  TrafficMap? _lastMap;
  int _closeReads = 0;
  int _clearReads = 0;

  /// True while coaching a rejoin.
  bool get active => _active;

  /// Feeds the latest state; returns the word to say now, if any.
  RejoinCall? update({
    required double speedKmh,
    required bool inPitLane,
    required TrafficMap traffic,
    required DateTime now,
    bool raceOver = false,
  }) {
    if (inPitLane || raceOver) {
      _standDown();
      return null;
    }
    if (speedKmh >= atSpeedKmh) _beenAtSpeed = true;

    if (!_active) {
      if (!_beenAtSpeed || speedKmh >= slowKmh) {
        _slowSince = null;
        return null;
      }
      final since = _slowSince ??= now;
      if (_seconds(now, since) < slowForS) return null;
      _active = true;
    }

    if (speedKmh >= rejoinedKmh || (_saidGo && speedKmh >= movingAgainKmh)) {
      _standDown();
      return null;
    }

    final next = traffic.nextArrivalSeconds();
    if (next == null) return null;
    final close = next < (_saidGo ? lateWaitSeconds : clearSeconds);
    if (!identical(traffic, _lastMap)) {
      // A new map reading (telemetry arrives far more often than the map).
      _lastMap = traffic;
      _closeReads = close ? _closeReads + 1 : 0;
      _clearReads = close ? 0 : _clearReads + 1;
    }

    if (close) {
      if (_closeReads < confirmReads) return null;
      _saidGo = false;
      final last = _lastWait;
      if (last != null && _seconds(now, last) < waitRepeatS) return null;
      _lastWait = now;
      return RejoinCall.wait;
    }
    if (_saidGo || _clearReads < confirmReads) return null;
    _saidGo = true;
    return RejoinCall.go;
  }

  void _standDown() {
    _active = false;
    _slowSince = null;
    _lastWait = null;
    _saidGo = false;
    _lastMap = null;
    _closeReads = 0;
    _clearReads = 0;
  }

  /// Session end: the next session starts from the grid.
  void reset() {
    _standDown();
    _beenAtSpeed = false;
  }

  static double _seconds(DateTime a, DateTime b) => a.difference(b).inMicroseconds / 1e6;
}
