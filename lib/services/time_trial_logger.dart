import '../models/telemetry_frame.dart';
import '../models/time_trial_lap.dart';

/// Records a [TimeTrialLap] each time a lap completes in Time Trialing
/// mode -- the same lap-boundary detection as PracticeLapLogger (lap
/// counter +1 with a valid last-lap time), but lap times only.
class TimeTrialLogger {
  final List<TimeTrialLap> _laps = [];
  int? _lastSeenLap;

  List<TimeTrialLap> get laps => List.unmodifiable(_laps);

  void seed(List<TimeTrialLap> laps) {
    _laps
      ..clear()
      ..addAll(laps);
    _lastSeenLap = null;
  }

  /// Feeds a frame in; returns true if a lap was just recorded.
  bool update(TelemetryFrame frame, {required String tireCompound, List<int>? sectorsMs}) {
    if (frame.currentLap <= 0) return false;
    final last = _lastSeenLap;
    _lastSeenLap = frame.currentLap;
    if (last == null || frame.currentLap != last + 1 || frame.lastLapTimeMs <= 0) return false;
    _laps.add(
      TimeTrialLap(
        lapTimeMs: frame.lastLapTimeMs,
        tireCompound: tireCompound,
        recordedAt: DateTime.now(),
        sectorsMs: sectorsMs,
      ),
    );
    return true;
  }

  /// Starts lap detection afresh (a new session) -- laps are kept.
  void startNewSession() => _lastSeenLap = null;

  void remove(DateTime recordedAt) => _laps.removeWhere((l) => l.recordedAt == recordedAt);

  void clear() {
    _laps.clear();
    _lastSeenLap = null;
  }
}
