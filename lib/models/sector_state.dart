/// Tracks live sector-split progress produced by the Bounding Box Sector
/// Calculator (Component A, Section 3).
class SectorState {
  final String? activeTrackName;
  final int currentSectorIndex; // 0 = sector 1, 1 = sector 2, 2 = sector 3
  final Duration? lastSplit;
  final List<Duration> completedSplits;

  const SectorState({
    this.activeTrackName,
    this.currentSectorIndex = 0,
    this.lastSplit,
    this.completedSplits = const [],
  });

  SectorState copyWith({
    String? activeTrackName,
    int? currentSectorIndex,
    Duration? lastSplit,
    List<Duration>? completedSplits,
  }) {
    return SectorState(
      activeTrackName: activeTrackName ?? this.activeTrackName,
      currentSectorIndex: currentSectorIndex ?? this.currentSectorIndex,
      lastSplit: lastSplit ?? this.lastSplit,
      completedSplits: completedSplits ?? this.completedSplits,
    );
  }
}
