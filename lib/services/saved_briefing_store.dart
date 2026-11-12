import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/race_briefing.dart';
import '../models/race_strategy.dart';
import '../models/strategy_validation.dart';
import 'practice_log_store.dart';
import 'pit_stop_time_store.dart';

/// Persists exactly one saved weekly briefing (+ its last-generated
/// strategy, and its last practice-session validation result, if any)
/// to on-device storage via SharedPreferences, so the Race Strategy
/// screen can reload it automatically every time the app starts rather
/// than the driver re-entering the same APRL briefing every session.
/// Deliberately a single slot (not a list of past rounds) per the
/// user's request -- the "name" (e.g. "Round 5") is just a label
/// overwritten each week, not a history.
///
/// The validation snapshot (saveValidation/load's third return value)
/// is how practice-lap data gets associated with a saved strategy:
/// since there's only ever one saved round at a time, "which round was
/// I practicing for" is implicitly "whichever one is currently saved"
/// -- every time the driver taps "VALIDATE AGAINST PRACTICE SESSION",
/// that result is written into THIS SAME slot, so reopening the app
/// shows the last validation for that round without needing to
/// re-drive practice laps. Practice laps themselves (see
/// PracticeLogStore) persist INDEFINITELY, across app restarts, until
/// either the driver clears them manually or saves under a DIFFERENT
/// round name -- editing/re-saving the SAME round (e.g. tweaking fuel%)
/// does NOT wipe practice laps, since that data took real driving
/// effort to gather and isn't invalidated by a form edit.
class SavedBriefingStore {
  static const _nameKey = 'saved_briefing_name';
  static const _briefingKey = 'saved_briefing_data';
  static const _strategyKey = 'saved_briefing_strategy';
  static const _validationKey = 'saved_briefing_validation';
  static const _validatedAtKey = 'saved_briefing_validated_at';

  /// Saves (overwriting any previous save) the named briefing, and
  /// optionally its generated strategy so that's restored too. Only
  /// clears the previous validation snapshot AND practice lap log when
  /// the round NAME actually changes (a genuinely new round) -- simply
  /// re-saving edits to the same round preserves both, since neither is
  /// invalidated by a form tweak.
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
      await prefs.remove(_validationKey);
      await prefs.remove(_validatedAtKey);
      await PracticeLogStore.clear();
      await PitStopTimeStore.clear();
    }
  }

  /// Records a practice-session validation result against the
  /// CURRENTLY saved round, with a timestamp -- called automatically
  /// every time the driver taps "VALIDATE AGAINST PRACTICE SESSION",
  /// so that snapshot persists across app restarts without needing a
  /// separate explicit save step.
  static Future<void> saveValidation(StrategyValidation validation) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_validationKey, jsonEncode(validation.toMap()));
    await prefs.setString(_validatedAtKey, DateTime.now().toIso8601String());
  }

  /// Loads the saved briefing (and strategy/validation snapshot, if
  /// saved alongside it), or null fields if nothing has been saved yet.
  static Future<(String?, RaceBriefing?, RaceStrategy?, StrategyValidation?, DateTime?)> load() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_nameKey);
    final briefingJson = prefs.getString(_briefingKey);
    final strategyJson = prefs.getString(_strategyKey);
    final validationJson = prefs.getString(_validationKey);
    final validatedAtString = prefs.getString(_validatedAtKey);

    final briefing = briefingJson != null
        ? RaceBriefing.fromMap(jsonDecode(briefingJson) as Map<String, dynamic>)
        : null;
    final strategy = strategyJson != null
        ? RaceStrategy.fromMap(jsonDecode(strategyJson) as Map<String, dynamic>)
        : null;
    final validation = validationJson != null
        ? StrategyValidation.fromMap(jsonDecode(validationJson) as Map<String, dynamic>)
        : null;
    final validatedAt = validatedAtString != null ? DateTime.tryParse(validatedAtString) : null;

    return (name, briefing, strategy, validation, validatedAt);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_nameKey);
    await prefs.remove(_briefingKey);
    await prefs.remove(_strategyKey);
    await prefs.remove(_validationKey);
    await prefs.remove(_validatedAtKey);
    await PracticeLogStore.clear();
    await PitStopTimeStore.clear();
  }
}
