/// Watches the live rivalPositions feed (see HudOverlayData, populated
/// by the laptop OCR relay's --rival-names) for a position CHANGE on
/// any of the driver's chosen championship rivals, and builds a
/// synthetic prompt for Boxington to call it out unprompted -- the same
/// "no push-to-talk needed" mechanism ProactiveCoachTrigger already
/// uses for shift-habit callouts (see VoiceEngine.speakProactively).
///
/// Phase B of the "nearest rival" feature (see championship_screen.dart
/// for Phase A's standings entry + rival selection) -- deliberately
/// starts with JUST position-change tracking, per the driver's request;
/// inferring a rival's tire strategy from their pace is a larger,
/// separate piece of work for a later phase.
class RivalMonitor {
  /// How many consecutive readings a NEW position must be seen for
  /// before it's accepted as a real change. A single OCR misread
  /// (P5 -> P8 -> P5) would otherwise produce two bogus callouts, one
  /// for the misread and one for "moving back". At the relay's 8Hz,
  /// the default of 2 adds only ~125ms of latency to a real move.
  final int stabilityThreshold;

  RivalMonitor({this.stabilityThreshold = 2});

  /// Last ACCEPTED position for each rival -- what a callout compares
  /// against.
  final Map<String, int> _lastKnownPosition = {};

  /// A not-yet-accepted new position per rival, and how many
  /// consecutive readings it's been seen for.
  final Map<String, int> _candidatePosition = {};
  final Map<String, int> _candidateCount = {};

  /// Resets tracked state for a fresh session (e.g. alongside a manual
  /// telemetry display reset) so a stale position from a PREVIOUS race
  /// doesn't get compared against this race's first reading and fire a
  /// spurious "rival moved" callout purely from session boundaries.
  void reset() {
    _lastKnownPosition.clear();
    _candidatePosition.clear();
    _candidateCount.clear();
  }

  /// Feeds the latest rivalPositions reading in. Returns a synthetic
  /// prompt for Boxington covering EVERY tracked rival whose position
  /// change was confirmed by this reading, or null if none was.
  ///
  /// The very first reading for a rival this session just establishes
  /// a baseline -- there's nothing to compare it against. A rival
  /// missing from the map (not on screen) is skipped and keeps any
  /// pending candidate, since a missing row isn't evidence either way.
  String? check(Map<String, int> rivalPositions) {
    final changes = <String>[];

    for (final entry in rivalPositions.entries) {
      final rivalName = entry.key;
      final newPosition = entry.value;
      final lastPosition = _lastKnownPosition[rivalName];

      if (lastPosition == null) {
        _lastKnownPosition[rivalName] = newPosition;
        continue;
      }

      if (newPosition == lastPosition) {
        // Back to (or still at) the accepted position -- any pending
        // candidate was noise.
        _candidatePosition.remove(rivalName);
        _candidateCount.remove(rivalName);
        continue;
      }

      final count = _candidatePosition[rivalName] == newPosition ? (_candidateCount[rivalName] ?? 0) + 1 : 1;
      _candidatePosition[rivalName] = newPosition;
      _candidateCount[rivalName] = count;
      if (count < stabilityThreshold) continue;

      _lastKnownPosition[rivalName] = newPosition;
      _candidatePosition.remove(rivalName);
      _candidateCount.remove(rivalName);

      final direction = newPosition < lastPosition ? 'moved up to' : 'dropped back to';
      changes.add('$rivalName just $direction P$newPosition (was P$lastPosition)');
    }

    if (changes.isEmpty) return null;
    if (changes.length == 1) {
      return 'Your championship rival ${changes.single}. Call this out briefly.';
    }
    return 'Your championship rivals moved: ${changes.join('; ')}. '
        'Call this out briefly in one transmission.';
  }
}
