import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/championship_standing.dart';
import 'championship_standings_store.dart';
import 'league_roster.dart';

/// The championship standings from the APRL leaderboard site
/// (aprl-leaderboard.anthonyreid004.workers.dev). The site reads every
/// race result from a public JSON feed; this reads the same feed and
/// totals our series the way the site does, so the APRL tab matches it.
class AprlLeaderboardService {
  /// The leaderboard's results feed: {ok, published, data: {results: [...]}}.
  static final Uri feedUrl = Uri.parse('https://aprl-feedback.anthonyreid004.workers.dev/data');

  /// Our series, if we can't find ourselves in the results.
  static const String defaultSeries = 'Development Series (GT3 Clubman)';

  /// Off in tests, so no test reaches the network (see
  /// test/flutter_test_config.dart).
  static bool enabled = true;

  static const _fetchedAtKey = 'aprl_standings_fetched_at';

  /// Fetches the feed, saves the standings in place of what's stored,
  /// and returns them. Throws if the leaderboard can't be reached or
  /// has nothing for our series (what's stored is kept).
  static Future<List<ChampionshipStanding>> refresh({http.Client? client}) async {
    if (!enabled) throw StateError('The leaderboard is off in tests');
    final c = client ?? http.Client();
    try {
      final response = await c.get(feedUrl).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw Exception('The leaderboard answered ${response.statusCode}');
      }
      final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      if (json['ok'] != true) throw Exception('The leaderboard has no results right now');
      final standings = standingsFrom(json);
      if (standings.isEmpty) throw Exception('No results for our series yet');
      await ChampionshipStandingsStore.save(standings);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_fetchedAtKey, DateTime.now().toIso8601String());
      return standings;
    } finally {
      if (client == null) c.close();
    }
  }

  /// When the standings were last taken from the leaderboard.
  static Future<DateTime?> lastFetched() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_fetchedAtKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  /// The series we race in: where our latest result is.
  static String seriesOf(List<Map<String, dynamic>> results) {
    final ours = results.where((r) => _key(r['driver']) == _key(playerName)).toList()
      ..sort((a, b) => _roundNumber(a['round']).compareTo(_roundNumber(b['round'])));
    return ours.isEmpty ? defaultSeries : ours.last['series'] as String;
  }

  /// Our series' standings from the feed, totalled as the site does:
  /// each driver's points per round, with the lowest round dropped
  /// (once two rounds have been run, counting a missed round as 0),
  /// ties broken on countback (most wins, then seconds...). Listed in
  /// that order, which ChampionshipStandingsStore keeps for ties.
  static List<ChampionshipStanding> standingsFrom(Map<String, dynamic> feed, {String? series}) {
    final data = feed['data'] as Map<String, dynamic>? ?? const {};
    if (data['series'] is List) return _fromTables(data['series'] as List, series: series);
    final all = [for (final r in (data['results'] as List? ?? const [])) r as Map<String, dynamic>];
    final ours = series ?? seriesOf(all);
    final results = all.where((r) => r['series'] == ours).toList();

    // One spelling per driver (the feed sometimes has "Willy_SwerveX"
    // for "Willy-SwerveX"): the most used, as the site does.
    final spellings = <String, Map<String, int>>{};
    for (final r in results) {
      final name = r['driver'] as String;
      final counts = spellings.putIfAbsent(_key(name), () => {});
      counts[name] = (counts[name] ?? 0) + 1;
    }
    String nameOf(String raw) =>
        spellings[_key(raw)]!.entries.reduce((a, b) => b.value > a.value ? b : a).key;

    final rounds = {for (final r in results) _roundNumber(r['round'])}.where((n) => n >= 1 && n <= 9).toSet();
    final points = <String, List<int?>>{};
    final places = <String, List<int>>{};
    for (final r in results) {
      final round = _roundNumber(r['round']);
      if (round < 1 || round > 9) continue;
      final name = nameOf(r['driver'] as String);
      final row = points.putIfAbsent(name, () => List<int?>.filled(9, null));
      row[round - 1] = (row[round - 1] ?? 0) + ((r['points'] as num?)?.round() ?? 0);
      final place = (r['place'] as num?)?.toInt();
      // A DNF etc. shows in raceTime, as the site reads it.
      final status = '${r['raceTime'] ?? ''}'.trim().toUpperCase();
      if (place != null && !const {'DNF', 'TDNF', 'DNS', 'DSQ'}.contains(status)) {
        places.putIfAbsent(name, () => []).add(place);
      }
    }

    final standings = [
      for (final MapEntry(key: name, value: row) in points.entries)
        ChampionshipStanding(
          driverName: name,
          roundPoints: row,
          dropPoints: rounds.length >= 2 ? rounds.map((n) => row[n - 1] ?? 0).reduce((a, b) => a < b ? a : b) : 0,
        ),
    ];
    int countback(ChampionshipStanding a, ChampionshipStanding b) {
      for (var p = 1; p <= 40; p++) {
        final ca = places[a.driverName]?.where((x) => x == p).length ?? 0;
        final cb = places[b.driverName]?.where((x) => x == p).length ?? 0;
        if (ca != cb) return cb - ca;
      }
      return a.driverName.toLowerCase().compareTo(b.driverName.toLowerCase());
    }

    standings.sort((a, b) => b.totalPoints != a.totalPoints ? b.totalPoints - a.totalPoints : countback(a, b));
    return standings;
  }

  /// The feed since Nov 2026: each series' finished table --
  /// {name, events: [{num, track}], rows: [{pos, driver, scores, dropIdx, total}]},
  /// rows in championship order (the page's division dropdown just picks
  /// one of these). Our series is the one we're in.
  static List<ChampionshipStanding> _fromTables(List tables, {String? series}) {
    final all = [for (final t in tables) t as Map<String, dynamic>];
    List rowsOf(Map<String, dynamic> t) => t['rows'] as List? ?? const [];
    bool hasUs(Map<String, dynamic> t) => rowsOf(t).any((r) => _key((r as Map)['driver']) == _key(playerName));
    final table = all.where((t) => t['name'] == series).firstOrNull ??
        all.where(hasUs).firstOrNull ??
        all.where((t) => t['name'] == defaultSeries).firstOrNull;
    if (table == null) return const [];

    final events = [for (final e in (table['events'] as List? ?? const [])) e as Map<String, dynamic>];
    return [
      for (final r in rowsOf(table))
        () {
          final row = r as Map<String, dynamic>;
          final scores = row['scores'] as List? ?? const [];
          final points = List<int?>.filled(9, null);
          for (var i = 0; i < scores.length; i++) {
            final round = i < events.length ? _roundNumber(events[i]['num']) : i + 1;
            if (round >= 1 && round <= 9) points[round - 1] = (scores[i] as num?)?.round();
          }
          final dropIdx = (row['dropIdx'] as num?)?.toInt();
          final drop = dropIdx != null && dropIdx >= 0 && dropIdx < scores.length ? (scores[dropIdx] as num?)?.round() ?? 0 : 0;
          return ChampionshipStanding(driverName: row['driver'] as String, roundPoints: points, dropPoints: drop);
        }(),
    ];
  }

  /// "R4 CB" -> 4.
  static int _roundNumber(Object? round) => int.tryParse(RegExp(r'\d+').firstMatch('$round')?.group(0) ?? '') ?? 0;

  static String _key(Object? name) => '$name'.toLowerCase().replaceAll(RegExp(r'[\s_\-.]'), '');
}
