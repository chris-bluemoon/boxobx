import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/championship_standing.dart';

/// Persists the LATEST weekly championship standings snapshot (one
/// entry per driver, see ChampionshipStanding) plus which 2 rivals the
/// driver has chosen to monitor -- both via SharedPreferences,
/// mirroring PitStopTimeStore/SavedBriefingStore's persistence style.
///
/// Deliberately keeps only the MOST RECENT week's standings, not a
/// history across weeks -- overwriting entirely on every save() is
/// intentional (matches the driver's stated minimal scope: position +
/// total + this week's round score, not a multi-week archive). If
/// week-over-week trend tracking is wanted later, this is the natural
/// place to extend into a keyed-by-week history instead.
class ChampionshipStandingsStore {
  static const _standingsKey = 'championship_standings';
  static const _rivalsKey = 'championship_rivals';

  static Future<void> save(List<ChampionshipStanding> standings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_standingsKey, jsonEncode(standings.map((s) => s.toMap()).toList()));
  }

  static Future<List<ChampionshipStanding>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_standingsKey);
    if (raw == null) return const [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => ChampionshipStanding.fromMap(e as Map<String, dynamic>)).toList();
  }

  /// Sorted by totalPoints descending (highest points = P1) -- position
  /// is always DERIVED this way rather than separately entered, so it
  /// can never drift out of sync with the totals (see
  /// ChampionshipStanding.totalPoints). A tie (two drivers on the same
  /// total, as the real league table shows for Chuck_E82/Willy-SwerveX
  /// at 66 points each) is broken by ORIGINAL list order, not
  /// arbitrarily -- Dart's List.sort() is not guaranteed stable, so
  /// ties are broken explicitly here via the original index rather
  /// than relying on sort() happening to preserve order.
  static List<ChampionshipStanding> sortedByPosition(List<ChampionshipStanding> standings) {
    final indexed = standings.indexed.toList();
    indexed.sort((a, b) {
      final pointsComparison = b.$2.totalPoints.compareTo(a.$2.totalPoints);
      return pointsComparison != 0 ? pointsComparison : a.$1.compareTo(b.$1);
    });
    return indexed.map((e) => e.$2).toList();
  }

  /// 1-indexed position of driverName within the standings, derived the
  /// same way as sortedByPosition, or null if that driver has no
  /// standings entry yet.
  static int? positionOf(String driverName, List<ChampionshipStanding> standings) {
    final sorted = sortedByPosition(standings);
    final index = sorted.indexWhere((s) => s.driverName == driverName);
    return index == -1 ? null : index + 1;
  }

  /// Points gap between driverName and rivalName (positive = driverName
  /// is ahead in points, negative = behind) -- null if either driver
  /// has no standings entry yet.
  static int? pointsGapTo(String driverName, String rivalName, List<ChampionshipStanding> standings) {
    final driver = standings.where((s) => s.driverName == driverName).firstOrNull;
    final rival = standings.where((s) => s.driverName == rivalName).firstOrNull;
    if (driver == null || rival == null) return null;
    return driver.totalPoints - rival.totalPoints;
  }

  /// Saves exactly the 2 gamertags the driver has chosen to monitor as
  /// championship rivals (see league_roster.dart) -- the "monitor
  /// functionality" these are used for is a separate, later piece of
  /// work (live on-track tracking of these specific drivers), this
  /// just persists WHO was chosen.
  static Future<void> saveRivals(List<String> rivalNames) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_rivalsKey, rivalNames);
  }

  static Future<List<String>> loadRivals() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_rivalsKey) ?? const [];
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_standingsKey);
    await prefs.remove(_rivalsKey);
  }
}
