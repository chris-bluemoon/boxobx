import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/race_briefing.dart';
import '../models/race_strategy.dart';
import 'app_database.dart';
import 'practice_log_store.dart';
import 'time_trial_store.dart';

/// The current round and each round's briefing (+ its last-generated
/// strategy). The current round is picked on the home page (from the
/// league calendar) or saved on the Race Strategy screen; everything
/// else follows it -- the header and track on every mode's page, the
/// strategy, the test plan, and which laps the logs show.
///
/// Briefings are kept per round in the app database, so switching to
/// another round and back finds each as it was left. Practice and
/// time-trial laps (see PracticeLogStore, TimeTrialStore) are kept per
/// round the same way. Renaming the SAME round (see [isSameRound], or
/// naming a round for the first time) takes its briefing and laps with
/// it.
class SavedBriefingStore {
  /// The current round's name, in SharedPreferences.
  static const _nameKey = 'saved_briefing_name';

  /// Saves [briefing] (and [strategy]) as round [name]'s and makes it the
  /// current round. Renaming the current round (or naming it for the
  /// first time) moves its laps and briefing to the new name; a
  /// genuinely different round leaves the old one's where they are.
  static Future<void> save({required String name, required RaceBriefing briefing, RaceStrategy? strategy}) async {
    final prefs = await SharedPreferences.getInstance();
    final previousName = prefs.getString(_nameKey);
    final isNewRound = previousName != null && !isSameRound(previousName, name);
    if (!isNewRound) await AppDatabase.renameRound(previousName ?? '', name);

    await AppDatabase.saveBriefing(
      name,
      jsonEncode(briefing.toMap()),
      strategy == null ? null : jsonEncode(strategy.toMap()),
    );
    await prefs.setString(_nameKey, name);
  }

  /// Makes [name] the current round, without saving anything: its own
  /// briefing and laps, if it has any, come back with it.
  static Future<void> selectRound(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await AppDatabase.instance; // older saves are imported first, under the old round
    await prefs.setString(_nameKey, name);
  }

  /// The round the lap logs are kept under: the current round's name,
  /// or '' before one is picked.
  static Future<String> currentRound() async {
    final prefs = await SharedPreferences.getInstance();
    await AppDatabase.instance;
    return prefs.getString(_nameKey) ?? '';
  }

  /// Round [name]'s saved briefing and strategy, or null if none.
  static Future<(RaceBriefing, RaceStrategy?)?> briefingFor(String name) async {
    final saved = await AppDatabase.loadBriefing(name);
    if (saved == null) return null;
    final strategyJson = saved.$2;
    return (
      RaceBriefing.fromMap(jsonDecode(saved.$1) as Map<String, dynamic>),
      strategyJson == null ? null : RaceStrategy.fromMap(jsonDecode(strategyJson) as Map<String, dynamic>),
    );
  }

  /// Every round with a saved briefing, most recently saved first.
  static Future<List<String>> savedRounds() => AppDatabase.roundsWithBriefings();

  /// The current round, and its briefing and strategy if saved (null
  /// fields otherwise). The trailing two tuple positions are kept
  /// (always null) for source-compatibility with callers that still
  /// destructure the old 5-element shape.
  static Future<(String?, RaceBriefing?, RaceStrategy?, Null, Null)> load() async {
    final prefs = await SharedPreferences.getInstance();
    await AppDatabase.instance;
    final name = prefs.getString(_nameKey);
    final saved = await briefingFor(name ?? '');
    return (name, saved?.$1, saved?.$2, null, null);
  }

  /// Whether two saved round names are the same round. Exact matches
  /// are, and so is a plain "Round 5" against the calendar's
  /// "Round 5 - Nürburgring Sprint" (see LeagueCalendar) -- renaming a
  /// round to its calendar name must not wipe its practice data.
  static bool isSameRound(String a, String b) => a == b || a.startsWith('$b - ') || b.startsWith('$a - ');

  /// Forgets the current round: its laps and briefing, then the round.
  static Future<void> clear() async {
    final round = await currentRound();
    await PracticeLogStore.clear(round: round);
    await TimeTrialStore.clear(round: round);
    await AppDatabase.deleteBriefing(round);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_nameKey);
  }
}
