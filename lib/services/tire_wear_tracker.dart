import '../models/telemetry_frame.dart';
import '../models/tire_wear_estimate.dart';

/// Derives a tire-degradation PROXY from GT7's raw lastLapTimeMs
/// telemetry, since GT7's packet has no tire-wear-percentage field at
/// all. Tracks completed-lap times within the CURRENT stint (reset on
/// every pit stop / manual reset) and compares each new lap against the
/// best lap recorded so far this stint -- a lap that's meaningfully
/// slower than the stint's best implies fading grip, and several such
/// laps in a row is a much stronger signal than one slow lap (which is
/// as likely to be traffic or a driver mistake as genuine tire wear).
///
/// Mirrors FuelPredictor's lap-detection pattern (watch currentLap for
/// a +1 increment to detect "a lap just completed") since both derive
/// their signal from the same lap-boundary event, just from different
/// telemetry fields.
class TireWearTracker {
  /// A lap must be at least this many percent slower than the stint's
  /// best lap to count as "degrading" at all -- filters out normal
  /// lap-to-lap variance (driver inconsistency, traffic) that isn't
  /// really tire wear.
  static const double _degradingLapThresholdPercent = 0.5;

  int? _lastSeenLap;
  int? _bestLapThisStintMs;
  int _consecutiveDegradingLaps = 0;
  double? _lastPercentSlower;

  /// Feeds a new telemetry frame in and returns the current estimate.
  /// Call this on every frame; it only reacts when it detects the lap
  /// counter has actually incremented (a new lap time became final).
  TireWearEstimate update(TelemetryFrame frame) {
    if (frame.currentLap <= 0) {
      return _currentEstimate();
    }

    if (_lastSeenLap == null) {
      _lastSeenLap = frame.currentLap;
      return _currentEstimate();
    }

    if (frame.currentLap != _lastSeenLap) {
      if (frame.currentLap == _lastSeenLap! + 1 && frame.lastLapTimeMs > 0) {
        _recordLap(frame.lastLapTimeMs);
      } else {
        // Lap count went backwards, jumped by more than 1, or the lap
        // time wasn't valid -- treat as a new stint/session and reset
        // rather than keep stale degradation history.
        reset();
      }
      _lastSeenLap = frame.currentLap;
    }

    return _currentEstimate();
  }

  void _recordLap(int lapTimeMs) {
    if (_bestLapThisStintMs == null || lapTimeMs < _bestLapThisStintMs!) {
      // New stint-best lap -- grip is at least as good as before, so
      // this isn't a degrading lap, and it resets the baseline every
      // other lap in the stint is compared against.
      _bestLapThisStintMs = lapTimeMs;
      _consecutiveDegradingLaps = 0;
      _lastPercentSlower = 0.0;
      return;
    }

    final percentSlower = ((lapTimeMs - _bestLapThisStintMs!) / _bestLapThisStintMs!) * 100;
    _lastPercentSlower = percentSlower;

    if (percentSlower >= _degradingLapThresholdPercent) {
      _consecutiveDegradingLaps++;
    } else {
      // Within noise of the stint best -- don't let a single
      // borderline lap break an otherwise-real degrading streak's
      // count, but don't count it as degrading either.
      _consecutiveDegradingLaps = 0;
    }
  }

  TireWearEstimate _currentEstimate() {
    if (_lastPercentSlower == null) {
      return TireWearEstimate.insufficientData();
    }
    return TireWearEstimate(
      percentSlowerThanStintBest: _lastPercentSlower,
      consecutiveDegradingLaps: _consecutiveDegradingLaps,
      hasEnoughData: true,
    );
  }

  /// Clears all tracked history -- call this whenever a new stint
  /// starts (a real pit stop for tires) or alongside a manual telemetry
  /// reset, so degradation data from a different/old set of tires
  /// doesn't linger and contaminate the new stint's baseline.
  void reset() {
    _lastSeenLap = null;
    _bestLapThisStintMs = null;
    _consecutiveDegradingLaps = 0;
    _lastPercentSlower = null;
  }
}
