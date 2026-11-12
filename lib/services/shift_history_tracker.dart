import '../models/telemetry_frame.dart';
import '../models/shift_event.dart';
import '../models/power_band_config.dart';

/// Tracks the driver's actual upshift habit over the last few gear
/// changes, rather than just showing a single live "shift now" gauge --
/// this answers "am I consistently over-revving or short-shifting",
/// which is the question a live-only gauge can't answer on its own.
///
/// Detects an upshift purely from the telemetry's gear number
/// increasing frame-to-frame (e.g. 2 -> 3), records the RPM from the
/// frame immediately before that increase (the RPM the driver actually
/// shifted at), and classifies it against [PowerBandConfig]. Downshifts
/// and neutral/reverse transitions are ignored entirely -- see the
/// class-level product decision to only track upshift timing.
class ShiftHistoryTracker {
  /// Number of most-recent upshifts to keep/display.
  static const int historyWindow = 5;

  final PowerBandConfig config;

  ShiftHistoryTracker({this.config = PowerBandConfig.bmwM6Gt3Endurance});

  int? _lastGear;
  double? _lastRpm;
  final List<ShiftEvent> _recentShifts = [];

  List<ShiftEvent> get recentShifts => List.unmodifiable(_recentShifts);

  /// Feeds a new telemetry frame in. Call this on every frame; it only
  /// records a shift event when it detects the gear count has actually
  /// increased versus the previous frame.
  void update(TelemetryFrame frame) {
    // Gear 0 is neutral -- a jump through neutral (e.g. 2 -> 0 -> 3, or
    // sitting in the pits) shouldn't be read as an upshift from
    // whatever gear was previously held, so just track it as the new
    // baseline without recording a shift.
    if (_lastGear != null && _lastRpm != null && frame.gear > _lastGear! && _lastGear! > 0) {
      _recentShifts.add(ShiftEvent(rpmAtShift: _lastRpm!, timing: _classify(_lastRpm!)));
      if (_recentShifts.length > historyWindow) {
        _recentShifts.removeAt(0);
      }
    }

    _lastGear = frame.gear;
    _lastRpm = frame.rpm;
  }

  ShiftTiming _classify(double rpm) {
    if (rpm >= config.overRevRpm) return ShiftTiming.late;
    if (rpm >= config.optimalShiftRpm) return ShiftTiming.good;
    return ShiftTiming.early;
  }

  /// Clears tracked shift history -- call this alongside a manual
  /// telemetry reset so a stale pattern from a previous session doesn't
  /// linger on screen (see FuelPredictor.reset for the same pattern).
  void reset() {
    _lastGear = null;
    _lastRpm = null;
    _recentShifts.clear();
  }
}
