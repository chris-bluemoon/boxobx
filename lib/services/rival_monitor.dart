/// Watches the live rivalPositions feed (see HudOverlayData, populated
/// by the laptop OCR relay's --rival-names) for a position CHANGE on
/// any of the driver's chosen championship rivals, and builds a
/// synthetic prompt for Gunther to call it out unprompted -- the same
/// "no push-to-talk needed" mechanism ProactiveCoachTrigger already
/// uses for shift-habit callouts (see VoiceEngine.speakProactively).
///
/// Phase B of the "nearest rival" feature (see championship_screen.dart
/// for Phase A's standings entry + rival selection) -- deliberately
/// starts with JUST position-change tracking, per the driver's request;
/// inferring a rival's tire strategy from their pace is a larger,
/// separate piece of work for a later phase.
class RivalMonitor {
  /// Last position seen for each rival, so a repeat reading of the SAME
  /// position across consecutive frames doesn't re-trigger a callout --
  /// only a genuine CHANGE from what was last reported does.
  final Map<String, int> _lastKnownPosition = {};

  /// Resets tracked state for a fresh session (e.g. alongside a manual
  /// telemetry display reset) so a stale position from a PREVIOUS race
  /// doesn't get compared against this race's first reading and fire a
  /// spurious "rival moved" callout purely from session boundaries.
  void reset() {
    _lastKnownPosition.clear();
  }

  /// Feeds the latest rivalPositions reading in. Returns a synthetic
  /// prompt string for Gunther to react to if a tracked rival's
  /// position just changed, or null if nothing changed (including the
  /// very first reading for a given rival this session, which just
  /// establishes a baseline rather than firing a callout -- there's
  /// nothing to compare a first-ever reading against).
  String? check(Map<String, int> rivalPositions) {
    for (final entry in rivalPositions.entries) {
      final rivalName = entry.key;
      final newPosition = entry.value;
      final lastPosition = _lastKnownPosition[rivalName];

      _lastKnownPosition[rivalName] = newPosition;

      if (lastPosition == null) {
        // First-ever reading for this rival this session -- nothing to
        // compare against yet, so just establish the baseline.
        continue;
      }

      if (newPosition == lastPosition) continue;

      final direction = newPosition < lastPosition ? 'moved up to' : 'dropped back to';
      return 'Your championship rival $rivalName just $direction P$newPosition '
          '(was P$lastPosition). Call this out briefly.';
    }

    return null;
  }
}
