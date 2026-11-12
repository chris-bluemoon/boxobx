import '../models/telemetry_frame.dart';
import '../models/practice_lap_record.dart';
import '../models/power_band_config.dart';

/// Builds a PracticeLapRecord every time a lap completes, from raw
/// telemetry plus whatever tire compound is currently selected on the
/// dashboard's tire picker (GT7's telemetry has no tire-compound field
/// at all, so this is the only source of truth for that part of the
/// record). Mirrors FuelPredictor/TireWearTracker's lap-boundary
/// detection (watch currentLap for a +1 increment), but instead of
/// computing a rolling average, keeps every individual lap so the
/// driver can see a full per-lap breakdown (lap time, tire, fuel).
///
/// Also tracks short-shifting/over-revving WITHIN each lap (mirroring
/// ShiftHistoryTracker's own upshift-detection + PowerBandConfig
/// classification, applied per-lap rather than as a rolling
/// cross-lap window) and attaches the counts to the completed
/// PracticeLapRecord -- both short-shifting and over-revving burn more
/// fuel than a clean shift for the same distance covered, so this is a
/// real input to how much a given lap's fuel-per-lap reading should be
/// trusted when predicting stint length, not just a display metric.
class PracticeLapLogger {
  final PowerBandConfig powerBandConfig;

  PracticeLapLogger({this.powerBandConfig = PowerBandConfig.bmwM6Gt3Endurance});

  int? _lastSeenLap;
  double? _fuelPercentAtLapStart;
  final List<PracticeLapRecord> _laps = [];

  // Shift tracking WITHIN the current, still-in-progress lap --
  // separate from ShiftHistoryTracker's own cross-lap rolling window,
  // since this needs to reset to zero at every lap boundary rather
  // than carry a fixed-size history across them.
  int? _lastShiftGear;
  double? _lastShiftRpm;
  int _currentLapShortShifts = 0;
  int _currentLapGoodShifts = 0;
  int _currentLapOverRevShifts = 0;

  /// Which tire compound to attribute to laps completed from now on --
  /// call this whenever the driver changes the dashboard's tire picker
  /// (including right before going out on a fresh set).
  String currentTireCompound = 'Racing Medium';

  /// When false, update() is a complete no-op -- nothing is recorded or
  /// persisted, and no lap is tagged to whichever round is currently
  /// saved. This is what makes "free practice" (not tied to any round)
  /// possible: flip logging off before driving, and those laps simply
  /// never enter the log at all. Defaults to true (logging-on) so
  /// existing behavior is unchanged unless the driver explicitly opts
  /// out via the dashboard's toggle.
  bool loggingEnabled = true;

  List<PracticeLapRecord> get laps => List.unmodifiable(_laps);

  /// Seeds the logger with laps already persisted from a previous app
  /// run (see PracticeLogStore) -- call this once right after
  /// construction/before the first telemetry frame arrives, so
  /// previously-logged laps aren't lost/overwritten by this session's
  /// (initially empty) in-memory list.
  void seedWithPersistedLaps(List<PracticeLapRecord> persistedLaps) {
    _laps
      ..clear()
      ..addAll(persistedLaps);
    _lastSeenLap = null;
    _fuelPercentAtLapStart = null;
  }

  /// Feeds a new telemetry frame in; appends a new PracticeLapRecord
  /// whenever it detects a completed lap. Call this on every frame.
  /// Does nothing at all while loggingEnabled is false (free practice).
  void update(TelemetryFrame frame) {
    if (!loggingEnabled) return;
    if (frame.currentLap <= 0) return;

    _trackShift(frame);

    if (_lastSeenLap == null) {
      _lastSeenLap = frame.currentLap;
      _fuelPercentAtLapStart = frame.fuelPercent;
      return;
    }

    if (frame.currentLap != _lastSeenLap) {
      if (frame.currentLap == _lastSeenLap! + 1 &&
          frame.lastLapTimeMs > 0 &&
          _fuelPercentAtLapStart != null) {
        _laps.add(PracticeLapRecord(
          lapNumber: _laps.length + 1,
          lapTimeMs: frame.lastLapTimeMs,
          tireCompound: currentTireCompound,
          fuelPercentAtLapStart: _fuelPercentAtLapStart!,
          fuelPercentAtLapEnd: frame.fuelPercent,
          shortShiftCount: _currentLapShortShifts,
          goodShiftCount: _currentLapGoodShifts,
          overRevShiftCount: _currentLapOverRevShifts,
          recordedAt: DateTime.now(),
        ));
      } else {
        // Lap count went backwards, jumped by more than 1, or missing
        // data -- treat as a new session and reset rather than mixing
        // laps from two different sessions/restarts together.
        _laps.clear();
      }
      _lastSeenLap = frame.currentLap;
      _fuelPercentAtLapStart = frame.fuelPercent;
      // The new lap starts with a clean slate of shift counts,
      // regardless of whether the previous lap just completed
      // successfully or was discarded above -- either way, shifts
      // from here belong to a DIFFERENT lap than whatever was just
      // counted/cleared.
      _currentLapShortShifts = 0;
      _currentLapGoodShifts = 0;
      _currentLapOverRevShifts = 0;
    }
  }

  /// Detects an upshift purely from the gear number increasing
  /// frame-to-frame (mirrors ShiftHistoryTracker's own detection
  /// logic exactly), classifies the RPM it happened at against
  /// powerBandConfig, and tallies it into the current lap's counters.
  /// Downshifts and neutral/reverse transitions are ignored, same as
  /// ShiftHistoryTracker.
  void _trackShift(TelemetryFrame frame) {
    if (_lastShiftGear != null && _lastShiftRpm != null && frame.gear > _lastShiftGear! && _lastShiftGear! > 0) {
      final rpm = _lastShiftRpm!;
      if (rpm >= powerBandConfig.overRevRpm) {
        _currentLapOverRevShifts++;
      } else if (rpm >= powerBandConfig.optimalShiftRpm) {
        _currentLapGoodShifts++;
      } else {
        _currentLapShortShifts++;
      }
    }
    _lastShiftGear = frame.gear;
    _lastShiftRpm = frame.rpm;
  }

  void reset() {
    _lastSeenLap = null;
    _fuelPercentAtLapStart = null;
    _lastShiftGear = null;
    _lastShiftRpm = null;
    _currentLapShortShifts = 0;
    _currentLapGoodShifts = 0;
    _currentLapOverRevShifts = 0;
    _laps.clear();
  }

  /// Deletes a single logged lap, identified by its recordedAt
  /// timestamp (unique per lap, unlike lapNumber which gets
  /// renumbered -- see below) -- lets the driver remove one bad/outlier
  /// lap (e.g. a spin, a lap interrupted by traffic) without wiping the
  /// whole practice log via reset().
  ///
  /// Remaining laps are renumbered sequentially (1, 2, 3...) after the
  /// deletion so lapNumber always reflects "the Nth lap in this log"
  /// with no gaps, and so a newly-logged lap afterward can't collide
  /// with a stale number from a deleted one.
  void removeLap(DateTime recordedAt) {
    _laps.removeWhere((lap) => lap.recordedAt == recordedAt);
    for (var i = 0; i < _laps.length; i++) {
      if (_laps[i].lapNumber != i + 1) {
        _laps[i] = _laps[i].withLapNumber(i + 1);
      }
    }
  }

  /// Toggles loggingEnabled and clears the in-progress lap-boundary
  /// tracking (NOT the already-recorded laps) -- so flipping logging
  /// off mid-lap and back on later doesn't compute a bogus lap-time
  /// delta across the gap; the next completed lap after re-enabling
  /// simply establishes a fresh baseline instead.
  void setLoggingEnabled(bool enabled) {
    loggingEnabled = enabled;
    _lastSeenLap = null;
    _fuelPercentAtLapStart = null;
  }
}
