import '../models/practice_lap_record.dart';

/// What a leaner fuel map really does, from this round's laps: laps run
/// on it (a fuel map stint test tags them -- PracticeLapRecord.fuelMap)
/// against the Map 1 laps. Until measured, PitStopCalculator goes by
/// the assumed figures.
class FuelMapMeasurement {
  final int map;

  /// Fuel used on [map] against Map 1 (0.8 = 20% saved).
  final double fuelFactor;

  /// Lap time given up against Map 1, as a share of the lap (0.012 =
  /// 1.2% slower) -- null when there are no Map 1 laps on the same tyre
  /// and a similar fuel load to set it against.
  final double? lapTimeLoss;

  /// Laps on [map] it rests on.
  final int laps;

  const FuelMapMeasurement({required this.map, required this.fuelFactor, this.lapTimeLoss, required this.laps});

  /// Laps needed on each map before a figure is used.
  static const int minLaps = 2;

  /// Map 1 laps count for the pace comparison when their starting fuel
  /// is within this of the map's laps (fuel weight moves lap times).
  static const double fuelWindowPercent = 20;

  static bool _usable(PracticeLapRecord l) => !l.isPitLap && l.lapTimeMs > 0 && l.fuelConsumedPercent > 0;
  static bool _onMap1(PracticeLapRecord l) => (l.fuelMap ?? 1) == 1;

  /// Map 1 laps' average fuel use, or null with too few.
  static double? map1PercentPerLap(List<PracticeLapRecord> laps) {
    final used = [for (final l in laps) if (_usable(l) && _onMap1(l)) l.fuelConsumedPercent];
    return used.length < minLaps ? null : used.reduce((a, b) => a + b) / used.length;
  }

  /// Every leaner map with enough laps on it, by map number.
  static Map<int, FuelMapMeasurement> fromLaps(List<PracticeLapRecord> laps) {
    final map1 = map1PercentPerLap(laps);
    if (map1 == null) return const {};
    final byMap = <int, List<PracticeLapRecord>>{};
    for (final l in laps) {
      if (_usable(l) && !_onMap1(l)) byMap.putIfAbsent(l.fuelMap!, () => []).add(l);
    }
    final result = <int, FuelMapMeasurement>{};
    for (final MapEntry(key: map, value: onMap) in byMap.entries) {
      if (onMap.length < minLaps) continue;
      final used = onMap.map((l) => l.fuelConsumedPercent).reduce((a, b) => a + b) / onMap.length;
      result[map] = FuelMapMeasurement(
        map: map,
        fuelFactor: (used / map1).clamp(0.3, 1.0),
        lapTimeLoss: _lapTimeLoss(onMap, laps),
        laps: onMap.length,
      );
    }
    return result;
  }

  /// Median lap on the map against the median Map 1 lap on the same tyre
  /// with a similar fuel load.
  static double? _lapTimeLoss(List<PracticeLapRecord> onMap, List<PracticeLapRecord> all) {
    final tyre = onMap.first.tireCompound;
    final fuels = onMap.map((l) => l.fuelPercentAtLapStart);
    final low = fuels.reduce((a, b) => a < b ? a : b) - fuelWindowPercent;
    final high = fuels.reduce((a, b) => a > b ? a : b) + fuelWindowPercent;
    final reference = [
      for (final l in all)
        if (_usable(l) && _onMap1(l) && l.spinCount == 0 && l.tireCompound == tyre && l.fuelPercentAtLapStart >= low && l.fuelPercentAtLapStart <= high)
          l.lapTimeMs,
    ];
    final mapTimes = [for (final l in onMap) if (l.spinCount == 0 && l.tireCompound == tyre) l.lapTimeMs];
    if (reference.length < minLaps || mapTimes.length < minLaps) return null;
    final loss = _median(mapTimes) / _median(reference) - 1;
    return loss < 0 ? 0 : loss;
  }

  static double _median(List<int> v) {
    final s = [...v]..sort();
    return s.length.isOdd ? s[s.length ~/ 2].toDouble() : (s[s.length ~/ 2 - 1] + s[s.length ~/ 2]) / 2;
  }
}
