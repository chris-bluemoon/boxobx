/// One driver's entry in the weekly league championship standings,
/// manually entered by the driver each week from the league's Discord
/// results report (a formatted image/table, not parseable text or an
/// API feed -- see league_roster.dart). Deliberately minimal: just
/// enough to compute "how many points behind/ahead is my rival" and
/// show a basic form trend, not the full table (car/team/per-round
/// breakdown/drops) the actual Discord report contains.
class ChampionshipStanding {
  /// Exact PSN gamertag, matching an entry in leagueRoster.
  final String driverName;

  /// Running total championship points AFTER this week's round, as
  /// shown in the league's standings report -- this is what
  /// positions get derived/sorted from (see
  /// ChampionshipStandingsStore.sortedByPosition), rather than a
  /// separately-entered position number that could drift out of sync
  /// with the totals if entered inconsistently.
  final int totalPoints;

  /// Points scored in just this week's round (e.g. "R3" column in the
  /// league's table) -- kept separate from totalPoints so week-to-week
  /// form is visible (a driver could have a high total from early
  /// rounds but be scoring poorly recently), not just the cumulative
  /// standing.
  final int roundPoints;

  const ChampionshipStanding({
    required this.driverName,
    required this.totalPoints,
    required this.roundPoints,
  });

  factory ChampionshipStanding.fromMap(Map<String, dynamic> map) => ChampionshipStanding(
        driverName: map['driverName'] as String,
        totalPoints: (map['totalPoints'] as num).toInt(),
        roundPoints: (map['roundPoints'] as num).toInt(),
      );

  Map<String, dynamic> toMap() => {
        'driverName': driverName,
        'totalPoints': totalPoints,
        'roundPoints': roundPoints,
      };

  ChampionshipStanding copyWith({int? totalPoints, int? roundPoints}) => ChampionshipStanding(
        driverName: driverName,
        totalPoints: totalPoints ?? this.totalPoints,
        roundPoints: roundPoints ?? this.roundPoints,
      );
}
