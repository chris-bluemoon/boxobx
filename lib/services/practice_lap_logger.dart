import '../models/corner_delta.dart';
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
  ///
  /// It's the most worn tyre's reading (see [currentWorstTyre]), not
  /// the average of the four.
  double? currentTireWearPercent;

  /// Which tyre [currentTireWearPercent] is: 'FL', 'FR', 'RL' or 'RR'.
  String? currentWorstTyre;

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

  /// The lap just completed against the round's time-trial best, corner
  /// by corner (see CornerDelta) -- set by FusedRaceStateManager on the
  /// frame the lap completes, like [completedLapSectorsMs]; null when it
  /// couldn't be compared.
  List<CornerDelta>? completedLapCornerDeltas;

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
    // Each session starts dry; the driver sets rain on the dashboard.
    _currentWeather = null;
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
      _startLap(frame);
      return;
    }

    if (frame.currentLap != _lastSeenLap) {
      final grip = _grip.finishLap();
      final water = _finishLapWater();
      if (frame.currentLap == _lastSeenLap! + 1 && frame.lastLapTimeMs > 0 && _fuelPercentAtLapStart != null) {
        _recordLap(frame, grip, water);
      }
      // Otherwise the lap count went backwards, jumped by more than 1,
      // or data was missing -- a new session/restart (e.g. leaving a
      // race and starting another, which takes the counter from N back
      // to 1). Only the lap-boundary baseline is re-established below;
      // already-recorded laps are deliberately KEPT. They're the
      // persisted log for the current round (see PracticeLogStore), and
      // clearing them here used to wipe every stored lap the first time
      // the driver started a second session.
      _startLap(frame);
    } else {
      _grip.update(frame);
    }
  }

  /// Spins on the lap in progress: the nearest corner of each (see
  /// PracticeLapRecord.spinCorners).
  final List<int> _currentLapSpins = [];

  /// A spin on the lap in progress, nearest [corner] (0 = unknown).
  void reportSpin(int corner) => _currentLapSpins.add(corner);

  void _startLap(TelemetryFrame frame) {
    _currentLapSpins.clear();
    _lastSeenLap = frame.currentLap;
    _fuelPercentAtLapStart = frame.fuelPercent;
    // The new lap starts with a clean slate of shift counts, whether or
    // not the previous lap was recorded.
    _currentLapShortShifts = 0;
    _currentLapGoodShifts = 0;
    _currentLapOverRevShifts = 0;
  }

  void _recordLap(TelemetryFrame frame, LapGrip? grip, double? water) {
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
        cornerDeltas: completedLapCornerDeltas,
        // A test's laps are run on its fuel map; otherwise Map 1.
        fuelMap: _currentTestNumber == null ? null : _currentTestFuelMap,
        wheelspinPercent: grip?.wheelspinPercent,
        tcsPercent: grip?.tcsPercent,
        lockupPercent: grip?.lockupPercent,
        weather: _currentWeather,
        waterPercent: water,
        spinCorners: List.of(_currentLapSpins),
      ),
    );
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

  /// The race the next race lap goes into (the Race tab's RACE chip).
  int get upcomingRaceNumber => _newRaceRequested || _currentRace == 0
      ? _laps.fold<int>(0, (m, l) => (l.raceNumber ?? 0) > m ? l.raceNumber! : m) + 1
      : _currentRace;

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

  /// Whether the current/requested test carries on through pit stops (the
  /// full race test) rather than ending at the first one.
  bool _currentThroughStops = false;
  bool _requestedThroughStops = false;

  /// The tyre the current/requested test is to be run on (null: any, as
  /// in the full race test, which changes tyres at its stops).
  String? _currentTestCompound;
  String? _requestedTestCompound;

  /// The fuel map the current/requested test is run on (null: Map 1).
  int? _currentTestFuelMap;
  int? _requestedTestFuelMap;

  /// A test run through its stops (the full race test): each stint's fuel
  /// map, and which stint of it the current/requested one is -- the map
  /// moves on at each stop.
  List<int>? _currentTestStintMaps;
  List<int>? _requestedTestStintMaps;
  int _currentTestStintIndex = 0;
  int _requestedTestStintIndex = 0;

  /// The running test's tyre, if it has one.
  String? get activeTestCompound =>
      activeTestNumber == null ? null : (_newStintRequested ? _requestedTestCompound : _currentTestCompound);

  /// A test is running and the laps are being logged on a different tyre
  /// from its own (the HUD read another tyre): those laps don't count
  /// towards it (see TestPlanTracker).
  bool get onWrongTyreForTest {
    final tyre = activeTestCompound;
    return tyre != null && tyre != currentTireCompound;
  }


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
  ///
  /// [pitStop]: started by a pit stop. A test started [throughStops] (the
  /// full race test) carries on into the stint after the stop.
  ///
  /// [testCompound]: the tyre the test is to be run on (see
  /// [onWrongTyreForTest]). [testFuelMap]: the map it's run on; a test run
  /// [throughStops] can give each stint's ([testStintMaps], in order).
  void startNewStint({
    int? testNumber,
    bool automatic = false,
    bool pitStop = false,
    bool throughStops = false,
    String? testCompound,
    int? testFuelMap,
    List<int>? testStintMaps,
  }) {
    if (automatic && _newStintRequested && _requestedTestNumber != null) return;
    final active = activeTestNumber;
    final throughStopsNow = _newStintRequested ? _requestedThroughStops : _currentThroughStops;
    // A stop also carries a test on when its stint so far has been on the
    // wrong tyre: that's the driver coming in to fit the right one.
    final wrongTyreSoFar = active != null &&
        !_newStintRequested &&
        _currentTestCompound != null &&
        !_laps.any((l) => l.stintNumber == _currentStint && l.tireCompound == _currentTestCompound);
    final carryOn = pitStop && active != null && (throughStopsNow || wrongTyreSoFar);
    if (carryOn) {
      final pending = _newStintRequested;
      final tyre = pending ? _requestedTestCompound : _currentTestCompound;
      final maps = pending ? _requestedTestStintMaps : _currentTestStintMaps;
      // A stop on the way: the test's next stint (and its map), unless
      // this one hasn't been driven yet.
      final index = pending ? _requestedTestStintIndex : _currentTestStintIndex + (throughStopsNow ? 1 : 0);
      final map = pending ? _requestedTestFuelMap : _currentTestFuelMap;
      _newStintRequested = true;
      _requestedTestNumber = active;
      _requestedThroughStops = throughStopsNow;
      _requestedTestCompound = tyre;
      _requestedTestStintMaps = maps;
      _requestedTestStintIndex = index;
      _requestedTestFuelMap = maps != null && index < maps.length ? maps[index] : map;
      return;
    }
    _newStintRequested = true;
    _requestedTestNumber = testNumber;
    _requestedThroughStops = testNumber != null && throughStops;
    _requestedTestCompound = testNumber == null ? null : testCompound;
    _requestedTestStintMaps = testNumber == null ? null : testStintMaps;
    _requestedTestStintIndex = 0;
    _requestedTestFuelMap = testNumber == null ? null : (testStintMaps?.firstOrNull ?? testFuelMap);
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
      _currentThroughStops = _requestedThroughStops;
      _currentTestCompound = _requestedTestCompound;
      _currentTestFuelMap = _requestedTestFuelMap;
      _currentTestStintMaps = _requestedTestStintMaps;
      _currentTestStintIndex = _requestedTestStintIndex;
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
    _currentThroughStops = false;
    _requestedThroughStops = false;
    _currentTestCompound = null;
    _requestedTestCompound = null;
    _currentTestFuelMap = null;
    _requestedTestFuelMap = null;
    _currentTestStintMaps = null;
    _requestedTestStintMaps = null;
    _currentTestStintIndex = 0;
    _requestedTestStintIndex = 0;
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
  void removeLap(DateTime recordedAt) => removeLaps({recordedAt});

  /// Counts laps already logged (a stint run without Starting its test)
  /// towards stint test [testNumber] -- the driver says it was that test.
  void countLapsAsTest(Set<DateTime> recordedAts, int testNumber) {
    for (var i = 0; i < _laps.length; i++) {
      if (recordedAts.contains(_laps[i].recordedAt)) _laps[i] = _laps[i].withTestNumber(testNumber);
    }
  }

  /// Deletes several laps at once (a whole stint), renumbering the rest
  /// as removeLap does.
  void removeLaps(Set<DateTime> recordedAts) {
    _laps.removeWhere((lap) => recordedAts.contains(lap.recordedAt));
    for (var i = 0; i < _laps.length; i++) {
      if (_laps[i].lapNumber != i + 1) {
        _laps[i] = _laps[i].withLapNumber(i + 1);
      }
    }
  }
}
