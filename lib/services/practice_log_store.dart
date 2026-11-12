import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/practice_lap_record.dart';

/// Persists the practice-lap log (see PracticeLapLogger) to on-device
/// storage, so laps survive an app restart -- answers "is the data
/// stored indefinitely": yes, until the driver explicitly clears it or
/// saves a NEW briefing (a new round), at which point the old round's
/// practice laps are no longer relevant and are cleared automatically
/// (mirroring SavedBriefingStore's validation-snapshot behavior).
///
/// Deliberately a single list (not one per round) for the same reason
/// SavedBriefingStore is a single slot: there's only ever one "current"
/// round being practiced for at a time.
class PracticeLogStore {
  static const _lapsKey = 'practice_log_laps';

  static Future<void> save(List<PracticeLapRecord> laps) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lapsKey, jsonEncode(laps.map((l) => l.toMap()).toList()));
  }

  static Future<List<PracticeLapRecord>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lapsKey);
    if (raw == null) return const [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => PracticeLapRecord.fromMap(e as Map<String, dynamic>)).toList();
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lapsKey);
  }
}
