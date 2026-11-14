import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/time_trial_lap.dart';

/// Persists Time Trialing laps for the current round, like
/// PracticeLogStore: kept across restarts, cleared when a round is saved
/// under a new name (see SavedBriefingStore) or by the driver.
class TimeTrialStore {
  static const _key = 'time_trial_laps';

  static Future<void> save(List<TimeTrialLap> laps) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(laps.map((l) => l.toMap()).toList()));
  }

  static Future<List<TimeTrialLap>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const [];
    return (jsonDecode(raw) as List).map((e) => TimeTrialLap.fromMap(e as Map<String, dynamic>)).toList();
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
