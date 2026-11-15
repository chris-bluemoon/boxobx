import '../models/time_trial_lap.dart';
import 'app_database.dart';
import 'saved_briefing_store.dart';

/// Persists Time Trialing laps for the current round in the app
/// database, like PracticeLogStore: kept across restarts, a fresh log
/// for each new round (earlier rounds' laps are kept as history), and
/// cleared by the driver.
class TimeTrialStore {
  ///
  /// [round] is the round the laps belong to, if the caller knows it
  /// (pass it when the save is queued, so a round saved meanwhile
  /// doesn't get them); otherwise the round saved now.
  static Future<void> save(List<TimeTrialLap> laps, {String? round}) async {
    round ??= await SavedBriefingStore.currentRound();
    await AppDatabase.replaceRound(AppDatabase.timeTrialLaps, round, [
      for (final (i, lap) in laps.indexed) AppDatabase.timeTrialRow(round, i, lap.toMap()),
    ]);
  }

  static Future<List<TimeTrialLap>> load() async {
    final round = await SavedBriefingStore.currentRound();
    final maps = await AppDatabase.loadRound(AppDatabase.timeTrialLaps, round);
    return maps.map(TimeTrialLap.fromMap).toList();
  }

  /// Clears the current round's time-trial laps.
  static Future<void> clear({String? round}) => save(const [], round: round);
}
