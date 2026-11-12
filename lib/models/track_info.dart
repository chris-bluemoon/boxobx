/// A single GT7 track entry for the Race Strategy briefing's track-name
/// dropdown. Deliberately minimal (just what the strategist/UI need)
/// compared to SectorCalculator's richer `_TrackDefinition` (which also
/// carries sector bounding boxes used for live lap-timing) -- the two
/// are kept separate so this UI-facing model doesn't need to change if
/// the sector-timing internals do, and vice versa.
class TrackInfo {
  final String name;
  final double trackLengthMeters;

  const TrackInfo({required this.name, required this.trackLengthMeters});

  factory TrackInfo.fromMap(Map<String, dynamic> map) => TrackInfo(
        name: map['name'] as String,
        trackLengthMeters: (map['trackLengthMeters'] as num).toDouble(),
      );
}
