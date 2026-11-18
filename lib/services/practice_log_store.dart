import 'dart:convert';

import '../models/league_calendar.dart';
import '../models/practice_lap_record.dart';
import '../models/race_briefing.dart';
import 'app_database.dart';
import 'saved_briefing_store.dart';

/// Persists the practice-lap log (see PracticeLapLogger) in the app
/// database, so laps survive an app restart. The laps belong to the
/// round saved on the strategy screen (see SavedBriefingStore): load()
/// returns the current round's, and saving a new round starts an empty
/// log while the earlier rounds' laps stay in the database as history.
/// Laps logged before any round is saved go with the first one saved.
class PracticeLogStore {
  /// Saves [laps] as the current round's whole log.
  ///
  /// [round] is the round the laps belong to, if the caller knows it
  /// (pass it when the save is queued, so a round saved meanwhile
  /// doesn't get them); otherwise the round saved now.
  static Future<void> save(List<PracticeLapRecord> laps, {String? round}) async {
    round ??= await SavedBriefingStore.currentRound();
    await AppDatabase.replaceRound(AppDatabase.practiceLaps, round, [
      for (final (i, lap) in laps.indexed) AppDatabase.practiceRow(round, i, lap.toMap()),
    ]);
  }

  static Future<List<PracticeLapRecord>> load() async {
    final round = await SavedBriefingStore.currentRound();
    final maps = await AppDatabase.loadRound(AppDatabase.practiceLaps, round);
    return maps.map(PracticeLapRecord.fromMap).toList();
  }

  /// Clears the current round's log.
  static Future<void> clear({String? round}) => save(const [], round: round);

  /// One round's laps (any round, not just the current one).
  static Future<List<PracticeLapRecord>> loadFor(String round) async {
    final maps = await AppDatabase.loadRound(AppDatabase.practiceLaps, round);
    return maps.map(PracticeLapRecord.fromMap).toList();
  }

  /// Every round with laps logged, most recently driven first.
  static Future<List<PracticeRoundSummary>> rounds() async => [
    for (final row in await AppDatabase.practiceRoundSummaries()) PracticeRoundSummary.fromRow(row),
  ];
}

/// A round in the Practice Log's list: the laps logged against it (each
/// lap row carries its round, like a foreign key to the round's brief).
class PracticeRoundSummary {
  final String round;
  final int laps;
  final int stints;
  final int raceLaps;
  final int? bestMs;
  final DateTime? lastDriven;

  /// The round's saved brief, if it has one (its track, weather, pit time).
  final RaceBriefing? briefing;

  const PracticeRoundSummary({
    required this.round,
    required this.laps,
    required this.stints,
    this.raceLaps = 0,
    this.bestMs,
    this.lastDriven,
    this.briefing,
  });

  factory PracticeRoundSummary.fromRow(Map<String, Object?> row) {
    RaceBriefing? briefing;
    final json = row['briefing'] as String?;
    if (json != null) {
      try {
        briefing = RaceBriefing.fromMap(jsonDecode(json) as Map<String, dynamic>);
      } catch (_) {}
    }
    return PracticeRoundSummary(
      round: row['round'] as String,
      laps: (row['laps'] as num).toInt(),
      stints: (row['stints'] as num).toInt(),
      raceLaps: (row['race_laps'] as num?)?.toInt() ?? 0,
      bestMs: (row['best_ms'] as num?)?.toInt(),
      lastDriven: DateTime.tryParse(row['last_driven'] as String? ?? ''),
      briefing: briefing,
    );
  }

  /// The track: from the round's brief, else the league calendar.
  String? get track => briefing?.trackName ?? LeagueCalendar.byName(round)?.gt7Track;
}
