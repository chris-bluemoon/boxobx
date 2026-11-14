/// What the laptop relay reads for a car currently showing GT7's "P"
/// (in pit lane) marker on the leaderboard.
class PitLaneEntry {
  /// Race position, or null if the relay couldn't read it.
  final int? position;

  /// Compound being fitted, as GT7's letter ("S", "M", "IM"...), or null
  /// if not shown/readable (yet).
  final String? tyre;

  /// Fuel amount going in, as shown next to GT7's pump icon, or null.
  final int? fuel;

  const PitLaneEntry({this.position, this.tyre, this.fuel});

  /// Accepts the relay's {"position","tyre","fuel"} object, or a bare
  /// position number (older relay versions).
  factory PitLaneEntry.fromJson(Object? value) {
    if (value is num) return PitLaneEntry(position: value > 0 ? value.toInt() : null);
    if (value is Map) {
      final position = (value['position'] as num?)?.toInt();
      return PitLaneEntry(
        position: position != null && position > 0 ? position : null,
        tyre: value['tyre'] as String?,
        fuel: (value['fuel'] as num?)?.toInt(),
      );
    }
    return const PitLaneEntry();
  }
}

/// Another driver's pit stop, as seen on GT7's leaderboard.
class OpponentPitStop {
  /// Roster PSN ID when the relay could resolve it, otherwise the
  /// on-screen name.
  final String driver;

  /// Their race position when they pitted, or null if unread.
  final int? position;

  /// OUR lap number at the time -- the closest lap reference available
  /// (the leaderboard doesn't show other drivers' lap counts).
  final int ourLap;

  /// Compound fitted (GT7 letter), and the largest fuel figure seen
  /// during the stop. Filled in while the driver is still in the pits.
  final String? tyre;
  final int? fuel;

  final DateTime seenAt;

  const OpponentPitStop({
    required this.driver,
    this.position,
    required this.ourLap,
    this.tyre,
    this.fuel,
    required this.seenAt,
  });

  OpponentPitStop withService({String? tyre, int? fuel}) => OpponentPitStop(
    driver: driver,
    position: position,
    ourLap: ourLap,
    tyre: tyre ?? this.tyre,
    fuel: fuel ?? this.fuel,
    seenAt: seenAt,
  );

  /// GT7 compound letter -> spoken name.
  static String? tyreName(String? letter) => switch (letter) {
    'S' => 'softs',
    'M' => 'mediums',
    'H' => 'hards',
    'IM' => 'inters',
    'W' => 'wets',
    _ => null,
  };

  Map<String, dynamic> toPromptContext() => {
    'driver': driver,
    if (position != null) 'position': position,
    'ourLap': ourLap,
    if (tyreName(tyre) != null) 'tyre': tyreName(tyre),
    if (fuel != null) 'fuelAdded': fuel,
  };
}
