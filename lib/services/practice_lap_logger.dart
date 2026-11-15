import '../models/telemetry_frame.dart';
import '../models/practice_lap_record.dart';
import '../models/power_band_config.dart';
import 'grip_tracker.dart';

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
  /// Swapped by FusedRaceStateManager when GT7 reports a different car.
  PowerBandConfig powerBandConfig;

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

  /// Latest average remaining-grip percent across all 4 wheels, read
  /// directly off GT7's HUD tire-wear widget by the laptop OCR relay
  /// (see laptop_ocr/tire_wear_reader.py) -- kept up to date by
  /// FusedRaceStateManager on every incoming HudOverlayData update, the
  /// same way currentTireCompound is kept up to date from the
  /// dashboard's tire picker. Automatically attached to a
  /// PracticeLapRecord at the moment its lap completes (see update()
  /// below), replacing what used to be a manual "log tire wear %"
  /// entry on the Practice Log screen -- GT7's telemetry packet itself
  /// has no tire-wear field at all, so this OCR reading is the only
  /// source of real (not proxied) wear data available.
  double? currentTireWearPercent;

  /// Latest reading of GT7's surface water gauge (percent), kept current
  /// by FusedRaceStateManager from the relay; see [reportWater].
  double? get currentWaterPercent => _currentWaterPercent;
  double? _currentWaterPercent;
  double _lapWaterSum = 0;
  int _lapWaterCount = 0;

  /// A water gauge reading from the relay. Each lap records the mean of
  /// the readings taken during it.
  void reportWater(double percent) {
    _currentWaterPercent = percent;
    _lapWaterSum += percent;
    _lapWaterCount++;
  }

  double? _finishLapWater() {
    final mean = _lapWaterCount == 0 ? null : double.parse((_lapWaterSum / _lapWaterCount).toStringAsFixed(1));
    _lapWaterSum = 0;
    _lapWaterCount = 0;
    return mean;
  }

  /// Sector times of the lap completing on the current frame (set by
  /// FusedRaceStateManager from SectorCalculator just before [update]).
  List<int>? completedLapSectorsMs;

  /// The GT7 weather being tested ("R01"-"R08"; null = dry), set on the
  /// dashboard -- attached to each lap like the tyre. Changing it starts
  /// a new stint (see setWeather), so each stint is one condition.
  String? get currentWeather => _currentWeather;
  String? _currentWeather;

  /// Sets the weather being tested; a change starts a new stint with the
  /// next lap.
  void setWeather(String? weather) {
    if (weather == _currentWeather) return;
    startNewStint();
    _currentWeather = weather;
  }

  /// Wheelspin / lock-ups over the lap in progress.
  final GripTracker _grip = GripTracker();

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
    // Carry on in the weather last tested (shown on the dashboard).
    _currentWeather = persistedLaps.isEmpty ? null : persistedLaps.last.weather;
    _lastSeenLap = null;
    _fuelPercentAtLapStart = null;
  }

  /// Feeds a new telemetry frame in; appends a new PracticeLapRecord
  /// whenever it detects a completed lap. Call this on every frame.
  void update(TelemetryFrame frame) {
    if (frame.currentLap <= 0) return;

    _trackShift(frame);

    if (_lastSeenLap == null) {
      _grip.reset();
      _finishLapWater();
      _lastSeenLap = frame.currentLap;
      _fuelPercentAtLapStart = frame.fuelPercent;
      return;
    }

    if (frame.currentLap != _lastSeenLap) {
      final grip = _grip.finishLap();
      final water = _finishLapWater();
      if (frame.currentLap == _lastSeenLap! + 1 && frame.lastLapTimeMs > 0 && _fuelPercentAtLapStart != null) {
        _laps.add(
          PracticeLapRecord(
            lapNumber: _laps.length + 1,
            lapTimeMs: frame.lastLapTimeMs,
            tireCompound: currentTireCompound,
            fuelPercentAtLapStart: _fuelPercentAtLapStart!,
            fuelPercentAtLapEnd: frame.fuelPercent,
            // Whatever the OCR relay most recently read off the HUD
            // tire-wear widget at the moment this lap crossed the line --
            // null if the relay isn't running/hasn't produced a
            // confident reading yet, same as currentTireWearPercent
            // itself.
            tireWearPercent: currentTireWearPercent,
            shortShiftCount: _currentLapShortShifts,
            goodShiftCount: _currentLapGoodShifts,
            overRevShiftCount: _currentLapOverRevShifts,
            recordedAt: DateTime.now(),
            isPitLap: _pitLapNumbers.contains(_lastSeenLap),
            stintNumber: _stintForNextLap(),
            isRaceLap: isRaceMode,
            testNumber: _currentTestNumber,
            raceNumber: isRaceMode ? _raceForNextLap() : null,
            position: currentPosition,
            sectorsMs: completedLapSectorsMs,
            wheelspinPercent: grip?.wheelspinPercent,
            tcsPercent: grip?.tcsPercent,
            lockupPercent: grip?.lockupPercent,
            weather: _currentWeather,
            waterPercent: water,
          ),
        );
      }
      // Otherwise the lap count went backwards, jumped by more than 1,
      // or data was missing -- a new session/restart (e.g. leaving a
      // race and starting another, which takes the counter from N back
      // to 1). Only the lap-boundary baseline is re-established below;
      // already-recorded laps are deliberately KEPT. They're the
      // persisted log for the current round (see PracticeLogStore), and
      // clearing them here used to wipe every stored lap the first time
      // the driver started a second session.
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
    } else {
      _grip.update(frame);
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

  /// True in Race Mode -- tags laps as race laps (see AppMode). Turning
  /// it on starts a new race with the next lap.
  bool get isRaceMode => _isRaceMode;
  set isRaceMode(bool value) {
    if (value && !_isRaceMode) _newRaceRequested = true;
    _isRaceMode = value;
  }

  bool _isRaceMode = false;

  /// The race laps are being added to (see PracticeLapRecord.raceNumber).
  int _currentRace = 0;
  bool _newRaceRequested = true;

  /// Latest race position read off the leaderboard -- attached to each
  /// lap as it completes (kept current by FusedRaceStateManager).
  int? currentPosition;

  int _raceForNextLap() {
    if (_newRaceRequested || _currentRace == 0) {
      final highest = _laps.fold<int>(0, (m, l) => (l.raceNumber ?? 0) > m ? l.raceNumber! : m);
      _currentRace = highest + 1;
      _newRaceRequested = false;
    }
    return _currentRace;
  }

  /// The stint laps are currently being added to; 0 = none yet.
  int _currentStint = 0;
  bool _newStintRequested = true;

  /// The planned test the current (or requested) stint is for, if the
  /// driver started one -- see startNewStint.
  int? _currentTestNumber;
  int? _requestedTestNumber;

  /// The test being run right now: the one just started from the
  /// dashboard (even before its first lap completes), or the current
  /// stint's. Null when not running a test.
  int? get activeTestNumber => _newStintRequested ? _requestedTestNumber : _currentTestNumber;

  /// The stint the next recorded lap belongs to (0 before any lap).
  int get currentStint => _currentStint;

  /// True when a new stint has been asked for but no lap of it has been
  /// recorded yet (so [currentStint] still names the previous one).
  bool get newStintPending => _newStintRequested;

  /// Starts a new stint with the next recorded lap (fresh tyres/fuel,
  /// a new run). Called automatically when going out on track and after
  /// a pit stop, and from the dashboard's NEW STINT button. Numbering
  /// only advances once a lap is actually recorded, so repeated calls
  /// never create empty stints.
  ///
  /// [testNumber]: the planned test the driver says this stint is for
  /// (see TestPlan). A stint started any other way -- automatically, or
  /// NEW STINT -- isn't a test, which is also how a test ends.
  ///
  /// [automatic]: started by the app (a pit stop, going out on track)
  /// rather than the driver. That never cancels a test the driver has
  /// just started but not yet driven a lap of -- the usual sequence is
  /// "start test", then pit to fit the tyres, and the pit stop must not
  /// undo the tap.
  void startNewStint({int? testNumber, bool automatic = false}) {
    if (automatic && _newStintRequested && _requestedTestNumber != null) return;
    _newStintRequested = true;
    _requestedTestNumber = testNumber;
  }

  /// The running test has reached its target: marks the test's last
  /// recorded lap (so the test counts as done even if the current lap is
  /// abandoned) and ends the test -- the next lap starts a normal stint.
  /// Returns false if there was no running test.
  bool completeActiveTest() {
    final test = activeTestNumber;
    if (test == null) return false;
    if (!_newStintRequested && _laps.isNotEmpty) {
      final last = _laps.last;
      if (last.testNumber == test && last.stintNumber == _currentStint) {
        _laps[_laps.length - 1] = last.withTestTargetReached();
      }
    }
    startNewStint();
    return true;
  }

  int _stintForNextLap() {
    if (_newStintRequested || _currentStint == 0) {
      final highest = _laps.fold<int>(0, (m, l) => l.stintNumber > m ? l.stintNumber : m);
      _currentStint = highest + 1;
      _currentTestNumber = _requestedTestNumber;
      _newStintRequested = false;
    }
    return _currentStint;
  }

  /// GT7 lap numbers (this session) that had a pit stop -- see
  /// markPitLaps.
  final Set<int> _pitLapNumbers = {};

  /// Flags the given GT7 lap numbers as pit laps, so their records get
  /// isPitLap = true when they complete. Called by FusedRaceStateManager
  /// when PitStopTracker detects a stop.
  void markPitLaps(Iterable<int> gameLapNumbers) => _pitLapNumbers.addAll(gameLapNumbers);

  /// Starts tracking a new GT7 session (e.g. after leaving the track)
  /// without touching recorded laps: the next lap boundary establishes
  /// a fresh baseline instead of being compared across sessions.
  void startNewSession() {
    startNewStint(automatic: true);
    // Each time out on track in Race Mode is a new race.
    _newRaceRequested = true;
    _lastSeenLap = null;
    _fuelPercentAtLapStart = null;
    _lastShiftGear = null;
    _lastShiftRpm = null;
    _currentLapShortShifts = 0;
    _currentLapGoodShifts = 0;
    _currentLapOverRevShifts = 0;
    _pitLapNumbers.clear();
    _grip.reset();
    _finishLapWater();
  }

  void reset() {
    _grip.reset();
    _finishLapWater();
    _currentWaterPercent = null;
    _currentRace = 0;
    _newRaceRequested = true;
    _currentStint = 0;
    _newStintRequested = true;
    _currentTestNumber = null;
    _requestedTestNumber = null;
    _pitLapNumbers.clear();
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
}
