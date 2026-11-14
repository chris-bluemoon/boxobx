/// One blob of opponent arrowhead(s) on GT7's course map (see the
/// laptop relay's minimap_tracker.py). Cars running nose-to-tail merge
/// into one blob, so [count] is an estimate.
class TrafficCar {
  /// Position around the lap, 0-1000 (same scale as
  /// TrafficMap.playerLapProgress).
  final double lapProgress;
  final int count;

  /// How long ago we passed this car's current point -- 0 up to one lap
  /// time. Null until the relay has recorded a full lap of our own
  /// trajectory.
  final double? secondsBehind;

  const TrafficCar({required this.lapProgress, this.count = 1, this.secondsBehind});

  factory TrafficCar.fromJson(Map<String, dynamic> json) => TrafficCar(
        lapProgress: (json['lapProgress'] as num).toDouble(),
        count: (json['count'] as num?)?.toInt() ?? 1,
        secondsBehind: (json['secondsBehind'] as num?)?.toDouble(),
      );
}

/// Every car's position around the lap relative to us, from GT7's
/// course map -- including cars the leaderboard doesn't show. Cars are
/// anonymous (the map's arrowheads are identical).
class TrafficMap {
  final bool trackReady;
  final double? playerLapProgress;

  /// Our most recent lap time as measured on the map, or null.
  final double? lapSeconds;
  final List<TrafficCar> cars;

  const TrafficMap({this.trackReady = false, this.playerLapProgress, this.lapSeconds, this.cars = const []});

  static const empty = TrafficMap();

  factory TrafficMap.fromJson(Map<String, dynamic>? json) {
    if (json == null) return empty;
    return TrafficMap(
      trackReady: json['trackReady'] as bool? ?? false,
      playerLapProgress: (json['playerLapProgress'] as num?)?.toDouble(),
      lapSeconds: (json['lapSeconds'] as num?)?.toDouble(),
      cars: [
        for (final car in (json['cars'] as List? ?? const [])) TrafficCar.fromJson(car as Map<String, dynamic>),
      ],
    );
  }

  /// Seconds from us around the shorter way: positive = behind us,
  /// negative = ahead of us. Null when timing isn't available yet.
  double? relativeSeconds(TrafficCar car) {
    final behind = car.secondsBehind;
    final lap = lapSeconds;
    if (behind == null || lap == null || lap <= 0) return null;
    return behind <= lap / 2 ? behind : behind - lap;
  }

  /// Compact summary for Boxington: how many cars are close behind/ahead,
  /// and the nearest few with their gap in seconds.
  Map<String, dynamic>? toPromptContext({double windowSeconds = 3.0, int nearest = 6}) {
    if (!trackReady || lapSeconds == null) return null;
    final timed = [
      for (final car in cars)
        if (relativeSeconds(car) != null) (car, relativeSeconds(car)!),
    ]..sort((a, b) => a.$2.abs().compareTo(b.$2.abs()));
    int countWhere(bool Function(double) test) =>
        timed.where((e) => test(e.$2)).fold(0, (sum, e) => sum + e.$1.count);
    return {
      'lapSeconds': double.parse(lapSeconds!.toStringAsFixed(1)),
      'carsWithin${windowSeconds.toStringAsFixed(0)}sBehind': countWhere((s) => s >= 0 && s <= windowSeconds),
      'carsWithin${windowSeconds.toStringAsFixed(0)}sAhead': countWhere((s) => s < 0 && -s <= windowSeconds),
      'nearestCars': [
        for (final (car, seconds) in timed.take(nearest))
          {'seconds': double.parse(seconds.toStringAsFixed(1)), if (car.count > 1) 'count': car.count},
      ],
    };
  }
}
