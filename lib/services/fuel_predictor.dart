import '../models/telemetry_frame.dart';
import '../models/fuel_prediction.dart';

/// Derives a "which lap should I pit for fuel" prediction from GT7's raw
/// per-frame fuelPercent + currentLap telemetry.
///
/// GT7's packet gives us an instantaneous fuel level and lap number, but
/// not a consumption rate or a pit-lap prediction directly -- this is
/// computed here by recording the fuel level at the start of each lap
/// (detected via a currentLap change) and measuring how much was burned
/// over the lap that just completed. A rolling average over the last
/// few completed laps smooths out one-off anomalies (e.g. a lap that
/// included a slow-down for traffic, or a formation/out lap).
class FuelPredictor {
  /// Number of most-recent completed laps to average consumption over.
  /// Lower = reacts faster to a genuine change in driving style/fuel
  /// map; higher = more stable against one noisy/atypical lap.
  static const int lapHistoryWindow = 3;

  int? _lastSeenLap;
  double? _fuelPercentAtLapStart;
  final List<double> _recentLapConsumption = [];

  /// Feeds a new telemetry frame in and returns the current prediction.
  /// Call this on every frame; it only updates its internal lap-start
  /// baseline when it detects the lap counter has actually incremented.
  FuelPrediction update(TelemetryFrame frame) {
    // currentLap defaults to 0 (see TelemetryFrame.empty()) when
    // telemetry hasn't started yet, or genuinely 0 while sitting in a
    // menu/replay -- don't treat that as lap data to track against.
    if (frame.currentLap <= 0) {
      return _currentPrediction();
    }

    if (_lastSeenLap == null) {
      // First frame with valid lap data -- establish the baseline but
      // we don't have a previous lap to measure consumption against yet.
      _lastSeenLap = frame.currentLap;
      _fuelPercentAtLapStart = frame.fuelPercent;
      return _currentPrediction();
    }

    if (frame.currentLap != _lastSeenLap) {
      // Lap just changed -- measure how much fuel was burned over the
      // lap that just ended, provided the lap count only advanced by
      // exactly one (a jump of more than 1 likely means a session
      // reset/restart, which should reset tracking instead of recording
      // a bogus consumption figure).
      if (frame.currentLap == _lastSeenLap! + 1 && _fuelPercentAtLapStart != null) {
        final consumed = _fuelPercentAtLapStart! - frame.fuelPercent;
        // Fuel level can only go down over a lap (barring a pit
        // refuel, which would show as consumed < 0) -- only record
        // genuine burn, not a refuel event, as lap consumption data.
        if (consumed > 0) {
          _recentLapConsumption.add(consumed);
          if (_recentLapConsumption.length > lapHistoryWindow) {
            _recentLapConsumption.removeAt(0);
          }
        }
      } else {
        // Lap count went backwards, jumped by more than 1, or we had no
        // baseline -- treat as a new session/restart and reset history
        // rather than keep stale data from a different run.
        _recentLapConsumption.clear();
      }

      _lastSeenLap = frame.currentLap;
      _fuelPercentAtLapStart = frame.fuelPercent;
    }

    return _currentPrediction(currentFuelPercent: frame.fuelPercent, currentLap: frame.currentLap);
  }

  FuelPrediction _currentPrediction({double? currentFuelPercent, int? currentLap}) {
    if (_recentLapConsumption.isEmpty || currentFuelPercent == null || currentLap == null) {
      return FuelPrediction.insufficientData();
    }

    final averagePerLap =
        _recentLapConsumption.reduce((a, b) => a + b) / _recentLapConsumption.length;

    if (averagePerLap <= 0) {
      return FuelPrediction.insufficientData();
    }

    final lapsRemaining = (currentFuelPercent / averagePerLap).floor();
    final predictedEmptyLap = currentLap + lapsRemaining;

    return FuelPrediction(
      predictedEmptyLap: predictedEmptyLap,
      percentPerLap: averagePerLap,
      hasEnoughData: true,
    );
  }

  /// Clears all tracked history -- call this alongside any manual
  /// telemetry reset (see DashboardScreen._resetTelemetryDisplay) so a
  /// stale prediction from a previous session doesn't linger on screen.
  void reset() {
    _lastSeenLap = null;
    _fuelPercentAtLapStart = null;
    _recentLapConsumption.clear();
  }
}
