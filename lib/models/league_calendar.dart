/// One round of the Apex Point Racing League calendar.
class LeagueRound {
  /// "Round 1" ... "Season Finale".
  final String round;
  final String dates;

  /// The circuit as the calendar names it, e.g. "Alsace Village (Reverse)".
  final String circuit;

  /// The same circuit as named in GT7 / the app's track list
  /// (assets/config/all_tracks.json), to pre-select the track.
  final String gt7Track;
  final bool variableWeather;
  final bool featureRace;

  /// Timed races (e.g. a 90-minute enduro); null for lap-count races.
  final int? raceLengthMinutes;

  const LeagueRound({
    required this.round,
    required this.dates,
    required this.circuit,
    required this.gt7Track,
    this.variableWeather = false,
    this.featureRace = false,
    this.raceLengthMinutes,
  });

  /// What the round is saved as, e.g. "Round 4 - Alsace Village (Reverse)".
  String get name => '$round - $circuit';

  /// e.g. "17/11 – 19/11 · variable weather".
  String get details => [
    dates,
    if (featureRace) 'feature race',
    if (variableWeather) 'variable weather',
    if (raceLengthMinutes != null) '$raceLengthMinutes min enduro',
  ].join(' · ');
}

/// APRL Season 12 -- the Tuesday "GT7 Development + Pro Series" column of
/// the official calendar (commencing Tuesday 20th October). Update this
/// list each season.
class LeagueCalendar {
  static const String season = 'APRL Season 12';

  static const List<LeagueRound> rounds = [
    LeagueRound(
      round: 'Round 1',
      dates: '20/10 – 22/10',
      circuit: 'Road Atlanta',
      gt7Track: 'Michelin Raceway Road Atlanta',
    ),
    LeagueRound(
      round: 'Round 2',
      dates: '27/10 – 29/10',
      circuit: 'Lago Maggiore West',
      gt7Track: 'Autodrome Lago Maggiore - West',
    ),
    LeagueRound(
      round: 'Round 3',
      dates: '03/11 – 05/11',
      circuit: 'Mount Panorama',
      gt7Track: 'Mount Panorama Motor Racing Circuit',
    ),
    LeagueRound(
      round: 'Round 4',
      dates: '10/11 – 12/11',
      circuit: 'Alsace Village (Reverse)',
      gt7Track: 'Alsace - Village (Reverse)',
    ),
    LeagueRound(
      round: 'Round 5',
      dates: '17/11 – 19/11',
      circuit: 'Nürburgring Sprint',
      gt7Track: 'Nürburgring Sprint',
      variableWeather: true,
    ),
    LeagueRound(
      round: 'Round 6',
      dates: '24/11 – 26/11',
      circuit: 'Sainte-Croix C',
      gt7Track: 'Circuit de Sainte-Croix - C',
    ),
    LeagueRound(round: 'Round 7', dates: '01/12 – 03/12', circuit: 'Yas Marina', gt7Track: 'Yas Marina Circuit'),
    LeagueRound(
      round: 'Round 8',
      dates: '08/12 – 10/12',
      circuit: 'Sportsland Sugo',
      gt7Track: 'SUGO International Racing Course',
      featureRace: true,
    ),
    LeagueRound(
      round: 'Season Finale',
      dates: '15/12 – 17/12',
      circuit: 'Watkins Glen Long',
      gt7Track: 'Watkins Glen Long Course',
      raceLengthMinutes: 90,
    ),
  ];

  static LeagueRound? byName(String name) => rounds.where((r) => r.name == name).firstOrNull;
}
