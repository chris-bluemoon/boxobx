import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_mode.dart';

/// Remembers the dashboard's Practice/Race toggle between launches.
class AppModeStore {
  static const _key = 'app_mode';

  static Future<AppMode> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppMode.fromName(prefs.getString(_key));
  }

  static Future<void> save(AppMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }
}
