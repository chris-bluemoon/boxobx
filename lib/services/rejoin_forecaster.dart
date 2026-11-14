import '../models/traffic_map.dart';

/// Where we'd come out if we pitted now (see [RejoinForecaster]).
class RejoinForecast {
  /// Pit-stop time loss the forecast assumes.
  final double pitLossSeconds;
  final bool pitLossMeasured;

  /// Cars (from the course map, so including lapped cars) that would go
  /// past while we're in the pits.
  final int carsPassingWhileStopped;

  /// Cars near us when we rejoin: seconds relative to us after the stop
  /// (positive = behind us, negative = ahead), nearest first.
  final List<double> rejoinTraffic;

  /// True if nobody would be within [RejoinForecaster.clearAirSeconds].
  final bool clearAir;

  const RejoinForecast({
    required this.pitLossSeconds,
    required this.pitLossMeasured,
    required this.carsPassingWhileStopped,
    required this.rejoinTraffic,
    required this.clearAir,
  });

  Map<String, dynamic> toPromptContext() => {
    'pitLossSeconds': double.parse(pitLossSeconds.toStringAsFixed(1)),
    'pitLossMeasured': pitLossMeasured,
    'carsPassingWhileStopped': carsPassingWhileStopped,
    'rejoinTraffic': [for (final s in rejoinTraffic) double.parse(s.toStringAsFixed(1))],
    'clearAir': clearAir,
  };
}

/// Forecasts traffic at the pit exit if we stopped now.
///
/// Model: everyone keeps roughly the same pace, so a stop costing
/// [pitLossSeconds] drops us that many seconds back around the lap --
/// we rejoin next to whoever is currently that far behind us. The pits
/// are at the start/finish line (GT7 draws no separate pit lane on its
/// map), so where the stop happens doesn't change who's around us after
/// it, only when. Ignores the slower in/out laps and cars pitting
/// themselves -- it's a "where do I come out" guide, not a lap-perfect
/// simulation.
class RejoinForecaster {
  /// Used until a pit stop has been measured -- the same assumption as
  /// PitStopCalculator's unmeasured default (22s pit lane + 3.5s tyres).
  static const double defaultPitLossSeconds = 25.5;

  /// Cars within this many seconds of us at the rejoin count as traffic.
  static const double trafficWindowSeconds = 3.0;

  /// No car this close means clear air.
  static const double clearAirSeconds = 1.5;

  static RejoinForecast? forecast(TrafficMap traffic, {double? measuredPitLossSeconds}) {
    final lap = traffic.lapSeconds;
    if (!traffic.trackReady || lap == null || lap <= 0) return null;

    final measured = measuredPitLossSeconds != null && measuredPitLossSeconds > 0;
    final pitLoss = measured ? measuredPitLossSeconds : defaultPitLossSeconds;

    var passing = 0;
    final nearby = <double>[];
    for (final car in traffic.cars) {
      final behind = car.secondsBehind;
      if (behind == null) continue;
      if (behind < pitLoss) passing += car.count;
      var relative = behind - pitLoss;
      if (relative > lap / 2) relative -= lap;
      if (relative <= -lap / 2) relative += lap;
      if (relative.abs() <= trafficWindowSeconds) {
        for (var i = 0; i < car.count; i++) {
          nearby.add(relative);
        }
      }
    }
    nearby.sort((a, b) => a.abs().compareTo(b.abs()));

    return RejoinForecast(
      pitLossSeconds: pitLoss,
      pitLossMeasured: measured,
      carsPassingWhileStopped: passing,
      rejoinTraffic: nearby,
      clearAir: !nearby.any((s) => s.abs() <= clearAirSeconds),
    );
  }
}
