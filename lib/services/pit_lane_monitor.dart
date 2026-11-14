import '../models/opponent_pit_stop.dart';

/// Turns the relay's per-frame "who has the P (in pits) marker" readings
/// into a log of other drivers' pit stops, one entry per actual visit.
///
/// * A stop is ANNOUNCED (returned from [check]) once the tyre compound
///   being fitted is known, or after [announceAfterReadings] readings
///   if it never shows -- GT7 may not draw the tyre/fuel boxes the
///   instant a car enters the pit lane, and the tyre choice is the
///   part worth hearing.
/// * While the driver stays in the pits, their logged stop keeps being
///   updated with the tyre and the largest fuel figure seen.
/// * A driver only counts as having LEFT the pits after being missing
///   for [exitReadings] consecutive readings, so an OCR flicker during
///   one stop can't log it twice. A later, genuine second stop is
///   logged again.
class PitLaneMonitor {
  final int announceAfterReadings;
  final int exitReadings;
  final DateTime Function() _now;

  PitLaneMonitor({this.announceAfterReadings = 3, this.exitReadings = 5, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final List<OpponentPitStop> _stops = [];

  /// Drivers currently in the pits -> index of their stop in [_stops].
  final Map<String, int> _stopIndex = {};
  final Map<String, int> _readingsSeen = {};
  final Map<String, int> _readingsMissing = {};
  final Set<String> _announced = {};

  /// Every stop seen this session, oldest first.
  List<OpponentPitStop> get stops => List.unmodifiable(_stops);

  /// Feeds one reading. Returns the stops that should be announced now.
  List<OpponentPitStop> check(Map<String, PitLaneEntry> driversInPit, {required int ourLap}) {
    final toAnnounce = <OpponentPitStop>[];

    for (final MapEntry(key: driver, value: entry) in driversInPit.entries) {
      final index = _stopIndex[driver];
      if (index == null) {
        _stopIndex[driver] = _stops.length;
        _stops.add(
          OpponentPitStop(
            driver: driver,
            position: entry.position,
            ourLap: ourLap,
            tyre: entry.tyre,
            fuel: entry.fuel,
            seenAt: _now(),
          ),
        );
        _readingsSeen[driver] = 1;
      } else {
        final stop = _stops[index];
        final fuel = entry.fuel != null && (stop.fuel == null || entry.fuel! > stop.fuel!) ? entry.fuel : null;
        _stops[index] = stop.withService(tyre: entry.tyre, fuel: fuel);
        _readingsSeen[driver] = _readingsSeen[driver]! + 1;
      }
      _readingsMissing[driver] = 0;

      final stop = _stops[_stopIndex[driver]!];
      if (!_announced.contains(driver) && (stop.tyre != null || _readingsSeen[driver]! >= announceAfterReadings)) {
        _announced.add(driver);
        toAnnounce.add(stop);
      }
    }

    for (final driver in _stopIndex.keys.toList()) {
      if (driversInPit.containsKey(driver)) continue;
      final missing = _readingsMissing[driver]! + 1;
      if (missing < exitReadings) {
        _readingsMissing[driver] = missing;
        continue;
      }
      // Left the pits. A driver who flickered out before being
      // announced is still announced once, rather than never.
      if (!_announced.contains(driver)) toAnnounce.add(_stops[_stopIndex[driver]!]);
      _stopIndex.remove(driver);
      _readingsSeen.remove(driver);
      _readingsMissing.remove(driver);
      _announced.remove(driver);
    }

    return toAnnounce;
  }

  void reset() {
    _stops.clear();
    _stopIndex.clear();
    _readingsSeen.clear();
    _readingsMissing.clear();
    _announced.clear();
  }
}
