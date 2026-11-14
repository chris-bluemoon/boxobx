/// Holds proactive (unprompted) Boxington callouts that arrived while he
/// was busy -- listening to push-to-talk, transcribing, or mid-reply --
/// so they're spoken once he's free instead of being silently dropped.
///
/// Callouts are race-situational, so they go stale: "rival just moved
/// up to P3" heard 30 seconds later is wrong, not just late. Anything
/// older than [maxAge] is discarded rather than spoken, and the queue
/// is capped at [maxLength] (oldest dropped first) so a burst of events
/// can't build up a backlog Boxington would spend the next minute on.
class ProactiveCalloutQueue {
  final Duration maxAge;
  final int maxLength;
  final DateTime Function() _now;

  ProactiveCalloutQueue({
    this.maxAge = const Duration(seconds: 15),
    this.maxLength = 3,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final List<(String, DateTime)> _items = [];

  int get length => _items.length;

  void add(String prompt) {
    _items.add((prompt, _now()));
    while (_items.length > maxLength) {
      _items.removeAt(0);
    }
  }

  /// Removes and returns the oldest callout that's still fresh, or null
  /// if none is (stale ones are discarded along the way).
  String? takeNext() {
    final now = _now();
    while (_items.isNotEmpty) {
      final (prompt, queuedAt) = _items.removeAt(0);
      if (now.difference(queuedAt) <= maxAge) return prompt;
    }
    return null;
  }

  void clear() => _items.clear();
}
