import 'dart:math' as math;

import '../models/corner.dart';
import '../models/reference_lap.dart';
import '../models/sector_map.dart';
import '../models/sector_state.dart';
import '../models/telemetry_frame.dart';
import 'corner_detector.dart';
import 'saved_briefing_store.dart';
import 'sector_map_store.dart';

/// Our own sector times. GT7 sends no sector data (nor track length or
/// lap distance), so the lines are learned from the driver's own
/// driving: the first full lap at a layout records the path, and lines
/// go a third and two thirds of the way round it by distance (see
/// SectorMap). They're saved for good, so the same lines -- and
/// comparable sector times -- are used every visit. The learning lap
/// itself is split too, once its lines exist.
///
/// Times come from GT7's packet counter (60 packets per second of game
/// time, unaffected by Wi-Fi drops), with each crossing interpolated
/// between packets, then squared up with GT7's official lap time so the
/// three sectors add up to it exactly. A lap whose clock disagrees with
/// GT7's by more than [_maxClockDriftMs] (e.g. paused mid-lap) gets no
/// sectors rather than wrong ones.
class SectorCalculator {
  final Future<void> Function(List<SectorMap> maps) _persist;

  SectorCalculator({Future<void> Function(List<SectorMap> maps)? persist}) : _persist = persist ?? SectorMapStore.save;

  static const int _maxClockDriftMs = 1500;

  /// Samples into a lap before its heading is known well enough to
  /// recognise the layout.
  static const int _samplesToRecognise = 10;

  final List<SectorMap> _maps = [];
  SectorMap? _map;

  int _frames = 0;
  int? _lastSeenLap;
  PathSample? _previous;

  /// The lap in progress: its path, start time and the S1/S2 lines'
  /// crossing times so far. Not valid if we joined it part-way round.
  final List<PathSample> _path = [];
  double _lapStart = 0;
  bool _lapValid = false;
  final List<double> _crossings = [];

  /// Live delta: the car being driven, and how far along its reference
  /// lap we've got (see ReferenceLap.locate).
  int _carCode = 0;
  int _referenceIndex = 0;
  int? _liveDeltaMs;

  /// The last clean lap's trace, and the reference it was driven
  /// against (before it replaced it, if it did) -- for the corner report.
  ReferenceLap? lastLapTrace;
  ReferenceLap? lastLapComparedTo;

  /// Corners of the layout being driven (empty until found).
  List<Corner> get corners => _map?.corners ?? const [];

  /// Whether completed laps may become the reference. Only Time
  /// Trialing laps do (always full grip and fuel, so comparable); stint
  /// and race laps are still split and compared, but never set it.
  bool recordsReference = true;

  /// The current round. References belong to the round they were set in,
  /// so a new round starts the delta afresh (its first clean Time
  /// Trialing lap becomes the reference).
  String? round;

  SectorState _state = const SectorState();
  SectorState get state => _state;

  List<SectorMap> get maps => List.unmodifiable(_maps);

  Future<void> loadSectorMaps() async {
    final stored = await SectorMapStore.load();
    _maps
      ..clear()
      ..addAll(stored);
  }

  /// For tests: start with these layouts already learned.
  void seedMaps(List<SectorMap> maps) => _maps
    ..clear()
    ..addAll(maps);

  /// Feeds one (driving) frame in.
  SectorState evaluate(TelemetryFrame frame) {
    _frames++;
    final sample = (
      x: frame.posX,
      z: frame.posZ,
      t: frame.packetId > 0 ? frame.packetId / 60.0 : _frames / 60.0,
      v: frame.speedKmh,
      brake: frame.brakePercent,
    );
    final previous = _previous;
    _previous = sample;
    _carCode = frame.carCode;
    var completed = false;

    final last = _lastSeenLap;
    _lastSeenLap = frame.currentLap;
    if (last == null) {
      _startLap(sample, null, valid: false);
    } else if (frame.currentLap != last) {
      if (frame.currentLap == last + 1) {
        completed = _completeLap(frame, sample, previous);
      }
      _startLap(sample, previous, valid: frame.currentLap == last + 1);
    } else {
      _path.add(sample);
      if (_lapValid && _path.length == _samplesToRecognise) _recogniseLayout();
      final map = _map;
      if (_lapValid && map != null && previous != null && _crossings.length < map.gates.length) {
        final t = SectorMap.crossingTime(map.gates[_crossings.length], previous, sample);
        if (t != null) _crossings.add(t);
      }
      _updateLiveDelta(sample);
    }

    _state = SectorState(
      currentSectorIndex: _crossings.length.clamp(0, 2),
      mapped: _map != null,
      currentLapSplitsMs: _lapValid ? _splitsSoFar() : const [],
      lastLapSectorsMs: _state.lastLapSectorsMs,
      lapJustCompleted: completed,
      liveDeltaMs: _liveDeltaMs,
      referenceLapMs: _reference?.lapTimeMs,
    );
    return _state;
  }

  /// The driver left the track: the next session may be another layout.
  void reset() {
    _map = null;
    _lastSeenLap = null;
    _previous = null;
    _path.clear();
    _crossings.clear();
    _lapValid = false;
    _liveDeltaMs = null;
    lastLapTrace = null;
    lastLapComparedTo = null;
    _state = const SectorState();
  }

  ReferenceLap? get _reference {
    final reference = _map?.references[_carCode];
    return reference != null && _isThisRound(reference) ? reference : null;
  }

  bool _isThisRound(ReferenceLap reference) {
    final a = reference.round, b = round;
    if (a == null || b == null) return a == b;
    return SavedBriefingStore.isSameRound(a, b);
  }

  /// Time now against the reference lap at the same point on track
  /// (negative = ahead). Null when there's no reference, the lap isn't
  /// timed, or the car is off the reference line (e.g. in the pits).
  void _updateLiveDelta(PathSample sample) {
    final reference = _reference;
    if (!_lapValid || reference == null) {
      _liveDeltaMs = null;
      return;
    }
    final at = reference.locate(sample.x, sample.z, _referenceIndex);
    if (at == null) {
      _liveDeltaMs = null;
      return;
    }
    _referenceIndex = at.index;
    _liveDeltaMs = ((sample.t - _lapStart) * 1000 - at.timeMs).round();
  }

  void _startLap(PathSample sample, PathSample? previous, {required bool valid}) {
    final map = _map;
    final lineCrossing = map == null || previous == null ? null : SectorMap.crossingTime(map.start, previous, sample);
    _lapStart = lineCrossing ?? sample.t;
    _lapValid = valid;
    _path
      ..clear()
      ..add(sample);
    _crossings.clear();
    _referenceIndex = 0;
    _liveDeltaMs = valid && _reference != null ? 0 : null;
  }

  /// Which known layout this lap is on, from where it started and which
  /// way it's heading; checked every lap.
  void _recogniseLayout() {
    final a = _path.first, b = _path.last;
    final dx = b.x - a.x, dz = b.z - a.z;
    final len = math.sqrt(dx * dx + dz * dz);
    if (len == 0) return;
    final norm = 1 / len;
    _map = _maps.where((m) => m.matches(a.x, a.z, dx * norm, dz * norm)).firstOrNull;
  }

  /// Closes the lap that just ended; true if it was a lap we timed.
  bool _completeLap(TelemetryFrame frame, PathSample sample, PathSample? previous) {
    lastLapTrace = null;
    lastLapComparedTo = null;
    if (!_lapValid || frame.lastLapTimeMs <= 0) {
      _state = SectorState(lastLapSectorsMs: null, mapped: _map != null);
      return true;
    }

    if (_map == null) {
      final learned = SectorMap.learn(_path);
      if (learned != null) {
        _maps.add(learned);
        _map = learned;
        _persist(List.of(_maps)).catchError((Object _) {});
        _crossings
          ..clear()
          ..addAll(_crossingsAlong(_path, learned));
      }
    }

    final map = _map;
    List<int>? sectors;
    if (map != null && _crossings.length == 2) {
      final end = (previous == null ? null : SectorMap.crossingTime(map.start, previous, sample)) ?? sample.t;
      final raw = [_crossings[0] - _lapStart, _crossings[1] - _crossings[0], end - _crossings[1]];
      final total = end - _lapStart;
      final official = frame.lastLapTimeMs;
      if (total > 0 && raw.every((s) => s > 0) && (total * 1000 - official).abs() <= _maxClockDriftMs) {
        final s1 = (official * raw[0] / total).round();
        final s2 = (official * raw[1] / total).round();
        sectors = [s1, s2, official - s1 - s2];
        final trace = ReferenceLap.fromPath(_path, _lapStart, end, official, round: round);
        lastLapComparedTo = _reference;
        lastLapTrace = trace;
        if (trace != null) _maybeNewReference(map, trace);
      }
    }
    _state = SectorState(lastLapSectorsMs: sectors, mapped: map != null);
    return true;
  }

  /// A clean lap faster than this car's reference here becomes the new
  /// reference (the first clean lap always does).
  void _maybeNewReference(SectorMap map, ReferenceLap lap) {
    if (!recordsReference) return;
    final current = map.references[_carCode];
    if (current != null && _isThisRound(current) && current.hasSpeedAndBrake && lap.lapTimeMs >= current.lapTimeMs) {
      return;
    }
    map.references[_carCode] = lap;
    // The layout's corners are found once, from its first reference.
    if (map.corners.isEmpty) map.corners.addAll(CornerDetector.detect(lap));
    _persist(List.of(_maps)).catchError((Object _) {});
  }

  static List<double> _crossingsAlong(List<PathSample> path, SectorMap map) {
    final found = <double>[];
    for (var i = 1; i < path.length && found.length < map.gates.length; i++) {
      final t = SectorMap.crossingTime(map.gates[found.length], path[i - 1], path[i]);
      if (t != null) found.add(t);
    }
    return found;
  }

  List<int> _splitsSoFar() {
    final splits = <int>[];
    var from = _lapStart;
    for (final c in _crossings) {
      splits.add(((c - from) * 1000).round());
      from = c;
    }
    return splits;
  }
}
