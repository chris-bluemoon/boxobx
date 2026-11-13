/// One driver's entry in the weekly league championship standings,
/// manually entered by the driver each week from the league's Discord
/// results report (a formatted image/table, not parseable text or an
/// API feed -- see league_roster.dart). Mirrors the real report's
/// columns (Round 1-9, Drop Points, Total) closely enough to track
/// week-to-week FORM (a driver scoring well early but fading recently
/// looks very different from one who's been consistent, which a
/// single cumulative total alone can't show).
class ChampionshipStanding {
  /// Exact PSN gamertag, matching an entry in leagueRoster.
  final String driverName;

  /// Points scored in each of the league's 9 rounds, in order
  /// (index 0 = Round 1 ... index 8 = Round 9) -- always exactly 9
  /// entries. Null for a round not yet raced/entered, distinct from 0
  /// (a genuine zero score, e.g. a DNF) -- see roundsRaced.
  final List<int?> roundPoints;

  /// Points dropped per the league's "best N of 9" drop-round rule
  /// (e.g. the real report's "DROP PTS" column) -- subtracted from the
  /// sum of roundPoints to get totalPoints.
  final int dropPoints;

  const ChampionshipStanding({
    required this.driverName,
    required this.roundPoints,
    this.dropPoints = 0,
  }) : assert(roundPoints.length == 9, 'roundPoints must have exactly 9 entries, one per round');

  /// Running total championship points -- ALWAYS derived as
  /// sum(roundPoints) - dropPoints, never entered directly, so it can
  /// never drift out of sync with the round-by-round scores the way a
  /// separately-typed total could (confirmed this formula matches the
  /// league's real report exactly: e.g. 26+31+35 - 26 dropped = 66).
  /// This is also what ChampionshipStandingsStore.sortedByPosition
  /// derives position from.
  int get totalPoints => roundPoints.fold<int>(0, (sum, points) => sum + (points ?? 0)) - dropPoints;

  /// How many of the 9 rounds have an actual entered score (null =
  /// not raced/not entered yet) -- used to distinguish "hasn't raced
  /// enough rounds to judge form" from "racing and just not scoring".
  int get roundsRaced => roundPoints.where((points) => points != null).length;

  factory ChampionshipStanding.fromMap(Map<String, dynamic> map) => ChampionshipStanding(
        driverName: map['driverName'] as String,
        roundPoints: (map['roundPoints'] as List).map((p) => (p as num?)?.toInt()).toList(),
        dropPoints: (map['dropPoints'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toMap() => {
        'driverName': driverName,
        'roundPoints': roundPoints,
        'dropPoints': dropPoints,
      };

  ChampionshipStanding copyWith({List<int?>? roundPoints, int? dropPoints}) => ChampionshipStanding(
        driverName: driverName,
        roundPoints: roundPoints ?? this.roundPoints,
        dropPoints: dropPoints ?? this.dropPoints,
      );
}
