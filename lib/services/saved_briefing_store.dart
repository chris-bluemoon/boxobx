import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/race_briefing.dart';
import '../models/race_strategy.dart';
import 'practice_log_store.dart';

/// Persists exactly one saved weekly briefing (+ its last-generated
/// strategy, if any) to on-device storage via SharedPreferences, so the
/// Race Strategy screen can reload it automatically every time the app
/// starts rather than the driver re-entering the same APRL briefing
/// every session. Deliberately a single slot (not a list of past
/// rounds) per the user's request -- the "name" (e.g. "Round 5") is
/// just a label overwritten each week, not a history.
///
/// Previously also persisted a practice-session "validation" snapshot
/// alongside the briefing -- removed as redundant: the generated
/// strategy already incorporates whatever practice laps exist at
/// generation time (see PracticeFuelCalculator), so re-comparing
/// against live telemetry after the fact added little beyond what
/// simply regenerating the strategy already does. Practice laps
/// themselves (see PracticeLogStore) persist INDEFINITELY, across app
/// restarts, until either the driver clears them manually or saves
/// under a DIFFERENT round name -- editing/re-saving the SAME round
/// (e.g. tweaking fuel%) does NOT wipe practice laps, since that data
/// took real driving effort to gather and isn't invalidated by a form
/// edit.
class SavedBriefingStore {
  static const _nameKey = 'saved_briefing_name';
  static const _briefingKey = 'saved_briefing_data';
  static const _strategyKey = 'saved_briefing_strategy';

  /// Saves (overwriting any previous save) the named briefing, and
  /// optionally its generated strategy so that's restored too. Only
  /// clears the practice lap log when the round NAME actually changes
  /// (a genuinely new round) -- simply re-saving edits to the same
  /// round preserves it, since it isn't invalidated by a form tweak.
  static Future<void> save({
    required String name,
    required RaceBriefing briefing,
    RaceStrategy? strategy,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final previousName = prefs.getString(_nameKey);
    final isNewRound = previousName != null && previousName != name;

    await prefs.setString(_nameKey, name);
    await prefs.setString(_briefingKey, jsonEncode(briefing.toMap()));
    if (strategy != null) {
      await prefs.setString(_strategyKey, jsonEncode(strategy.toMap()));
    } else {
      await prefs.remove(_strategyKey);
    }

    if (isNewRound) {
      await PracticeLogStore.clear();
    }
  }

  /// Loads the saved briefing (and strategy, if saved alongside it), or
  /// null fields if nothing has been saved yet. The trailing two tuple
  /// positions are kept (always null) purely for source-compatibility
  /// with existing callers/tests that still destructure the old
  /// 5-element shape from when a practice-session validation snapshot
  /// was also persisted here.
  static Future<(String?, RaceBriefing?, RaceStrategy?, Null, Null)> load() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_nameKey);
    final briefingJson = prefs.getString(_briefingKey);
    final strategyJson = prefs.getString(_strategyKey);

    final briefing = briefingJson != null
        ? RaceBriefing.fromMap(jsonDecode(briefingJson) as Map<String, dynamic>)
        : null;
    final strategy = strategyJson != null
        ? RaceStrategy.fromMap(jsonDecode(strategyJson) as Map<String, dynamic>)
        : null;

    return (name, briefing, strategy, null, null);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_nameKey);
    await prefs.remove(_briefingKey);
    await prefs.remove(_strategyKey);
    await PracticeLogStore.clear();
  }
}
