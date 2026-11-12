import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/pit_stop_time_record.dart';

/// Persists manually-entered pit-stop time-loss measurements (see
/// PitStopTimeRecord), mirroring PracticeLogStore's lifecycle exactly:
/// persists indefinitely across app restarts, survives edits to the
/// SAME saved round, and is cleared when SavedBriefingStore.save() is
/// called under a genuinely NEW round name (via SavedBriefingStore
/// itself) or explicitly by the driver.
class PitStopTimeStore {
  static const _recordsKey = 'pit_stop_time_records';

  static Future<void> save(List<PitStopTimeRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_recordsKey, jsonEncode(records.map((r) => r.toMap()).toList()));
  }

  static Future<List<PitStopTimeRecord>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_recordsKey);
    if (raw == null) return const [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => PitStopTimeRecord.fromMap(e as Map<String, dynamic>)).toList();
  }

  static Future<void> addRecord(PitStopTimeRecord record) async {
    final existing = await load();
    await save([...existing, record]);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_recordsKey);
  }

  /// Average measured time loss across all logged stops, or null if
  /// none have been logged yet -- what PitStopCalculator actually
  /// consumes (a single representative number, rather than a full
  /// distribution).
  static double? averageTimeLossSeconds(List<PitStopTimeRecord> records) {
    if (records.isEmpty) return null;
    return records.map((r) => r.totalTimeLossSeconds).reduce((a, b) => a + b) / records.length;
  }
}
