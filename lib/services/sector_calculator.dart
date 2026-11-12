import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;

import '../models/sector_state.dart';
import '../models/telemetry_frame.dart';

class _BoundingBox {
  final double minX, maxX, minZ, maxZ;
  _BoundingBox({required this.minX, required this.maxX, required this.minZ, required this.maxZ});

  bool contains(double x, double z) => x >= minX && x <= maxX && z >= minZ && z <= maxZ;

  factory _BoundingBox.fromMap(Map<String, dynamic> map) => _BoundingBox(
        minX: (map['minX'] as num).toDouble(),
        maxX: (map['maxX'] as num).toDouble(),
        minZ: (map['minZ'] as num).toDouble(),
        maxZ: (map['maxZ'] as num).toDouble(),
      );
}

class _TrackDefinition {
  final String name;
  final double trackLengthMeters;
  final _BoundingBox sector1;
  final _BoundingBox sector2;

  _TrackDefinition({
    required this.name,
    required this.trackLengthMeters,
    required this.sector1,
    required this.sector2,
  });

  factory _TrackDefinition.fromMap(Map<String, dynamic> map) => _TrackDefinition(
        name: map['name'] as String,
        trackLengthMeters: (map['trackLengthMeters'] as num).toDouble(),
        sector1: _BoundingBox.fromMap(map['sector1Boundary']),
        sector2: _BoundingBox.fromMap(map['sector2Boundary']),
      );
}

/// Component A (Section 3): Bounding Box Sector Calculator.
///
/// Cross-references the live track length against tracks_db.json. If a
/// match is found, live X/Z coordinates are evaluated against the mapped
/// sector bounding boxes to trigger sector splits with millisecond
/// precision. If no match is found, falls back to dividing the track
/// into three mathematically equal distance slices.
///
/// tracks_db.json is generated (see tools/generate_tracks_db.py) from the
/// public domain (CC0) GT7 track dataset at
/// github.com/jbhoorasingh/gt7-datalogger-track-data. That project does
/// not publish GT7's actual (undocumented, not exposed via telemetry or
/// any public API) in-game sector boundaries, so the sector1/sector2
/// bounding boxes here are *approximated*: small boxes centered on the
/// points 1/3 and 2/3 of the way around each track's surveyed/captured
/// racing-line path. This is more accurate than a blind hand-guessed box
/// (it's anchored to the real track shape) but will not line up exactly
/// with GT7's own sector timing lines.
class SectorCalculator {
  List<_TrackDefinition> _tracks = [];
  bool _loaded = false;

  final Stopwatch _stopwatch = Stopwatch();
  SectorState _state = const SectorState();
  bool _hasEnteredSector1 = false;
  bool _hasEnteredSector2 = false;

  static const double _trackLengthToleranceMeters = 15.0;

  Future<void> loadTrackDatabase() async {
    if (_loaded) return;
    final raw = await rootBundle.loadString('assets/config/tracks_db.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    _tracks = (json['tracks'] as List)
        .map((e) => _TrackDefinition.fromMap(e as Map<String, dynamic>))
        .toList();
    _loaded = true;
  }

  SectorState get state => _state;

  /// Feeds a new telemetry frame into the calculator and returns the
  /// (possibly updated) [SectorState].
  SectorState evaluate(TelemetryFrame frame) {
    if (!_stopwatch.isRunning) _stopwatch.start();

    final matchedTrack = _matchTrack(frame.trackLength);

    if (matchedTrack != null) {
      _state = _state.copyWith(activeTrackName: matchedTrack.name);
      _evaluateBoundingBoxes(frame, matchedTrack);
    } else {
      _evaluateEqualDistanceFallback(frame);
    }

    return _state;
  }

  _TrackDefinition? _matchTrack(double trackLength) {
    if (trackLength <= 0) return null;
    for (final track in _tracks) {
      if ((track.trackLengthMeters - trackLength).abs() <= _trackLengthToleranceMeters) {
        return track;
      }
    }
    return null;
  }

  void _evaluateBoundingBoxes(TelemetryFrame frame, _TrackDefinition track) {
    if (!_hasEnteredSector1 && track.sector1.contains(frame.posX, frame.posZ)) {
      _hasEnteredSector1 = true;
      _recordSplit();
    } else if (_hasEnteredSector1 &&
        !_hasEnteredSector2 &&
        track.sector2.contains(frame.posX, frame.posZ)) {
      _hasEnteredSector2 = true;
      _recordSplit();
    }
  }

  /// Dynamic Fallback Logic: slice the track distance into three
  /// mathematically equal pieces and use them as sector tripwires.
  void _evaluateEqualDistanceFallback(TelemetryFrame frame) {
    if (frame.trackLength <= 0) return;
    final sliceLength = frame.trackLength / 3;

    if (!_hasEnteredSector1 && frame.lapDistance >= sliceLength) {
      _hasEnteredSector1 = true;
      _recordSplit();
    } else if (_hasEnteredSector1 &&
        !_hasEnteredSector2 &&
        frame.lapDistance >= sliceLength * 2) {
      _hasEnteredSector2 = true;
      _recordSplit();
    } else if (_hasEnteredSector2 && frame.lapDistance < sliceLength) {
      // Crossed the start/finish line — new lap, reset tripwires.
      _hasEnteredSector1 = false;
      _hasEnteredSector2 = false;
    }
  }

  void _recordSplit() {
    _stopwatch.stop();
    final split = _stopwatch.elapsed;
    final updatedSplits = [..._state.completedSplits, split];
    final nextSectorIndex = (_state.currentSectorIndex + 1) % 3;

    _state = _state.copyWith(
      currentSectorIndex: nextSectorIndex,
      lastSplit: split,
      completedSplits: updatedSplits,
    );

    _stopwatch
      ..reset()
      ..start();

    if (nextSectorIndex == 0) {
      _hasEnteredSector1 = false;
      _hasEnteredSector2 = false;
    }
  }
}
