import '../models/practice_lap_record.dart';
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
}
