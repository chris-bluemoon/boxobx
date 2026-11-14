import 'package:shared_preferences/shared_preferences.dart';

/// Remembers the chosen race rival (Race Mode) between launches.
class RaceRivalStore {
  static const _key = 'race_rival';

  static Future<String?> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  static Future<void> save(String? name) async {
    final prefs = await SharedPreferences.getInstance();
    if (name == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, name);
    }
  }
}
