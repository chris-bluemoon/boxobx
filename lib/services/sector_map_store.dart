import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/sector_map.dart';

/// Every circuit's learned sector lines (see SectorMap), kept on the
/// device for good -- unlike laps, they don't belong to a round, so the
/// same lines (and comparable sector times) are used every visit.
class SectorMapStore {
  static const _key = 'sector_maps';

  static Future<List<SectorMap>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      return [for (final m in jsonDecode(raw) as List) SectorMap.fromMap(m as Map<String, dynamic>)];
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<SectorMap> maps) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode([for (final m in maps) m.toMap()]));
  }
}
