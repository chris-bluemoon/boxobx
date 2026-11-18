import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

/// The app's SQLite database: each round's briefing and strategy (see
/// SavedBriefingStore) and the lap logs, kept per round so earlier
/// rounds stay on the phone as history (see PracticeLogStore and
/// TimeTrialStore). Small settings stay in SharedPreferences.
///
/// Each lap row has the columns worth querying on (round, stint, tyre,
/// lap time, ...) plus the whole record as JSON in `data`, which is what
/// gets read back -- so a new field on a lap record needs no schema
/// change, only a new column if it's to be queried.
///
/// Uses the synchronous sqlite3 API (SQLite is bundled with the app by
/// sqlite3_flutter_libs): writes are once a lap and take milliseconds in
/// WAL mode, and synchronous calls behave the same in widget tests'
/// fake-async zone as in the app.

class AppDatabase {
  static const _fileName = 'boxbox.db';

  /// Bumped when the tables change; see [_migrate].
  static const _schemaVersion = 2;

  static const practiceLaps = 'practice_laps';
  static const timeTrialLaps = 'time_trial_laps';
  static const roundBriefings = 'round_briefings';

  static Database? _db;
  static Future<Database>? _opening;

  /// The open database (opened, and older SharedPreferences data
  /// imported, on first use). Once open it's handed out in a new future
  /// each time, made in the caller's zone -- a future made in another
  /// zone never completes inside a widget test's fake-async zone.
  static Future<Database> get instance {
    final db = _db;
    if (db != null) return Future.value(db);
    return _opening ??= _open().then((db) => _db = db);
  }

  static Future<Database> _open() async {
    final dir = await getApplicationSupportDirectory();
    final db = sqlite3.open(p.join(dir.path, _fileName));
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = NORMAL');
    _migrate(db);
    await _importFromSharedPreferences(db);
    return db;
  }

  static void _migrate(Database db) {
    if (db.userVersion >= _schemaVersion) return;
    db.execute('BEGIN');
    try {
      if (db.userVersion < 1) _createTables(db);
      if (db.userVersion < 2) _createRoundBriefings(db);
      db.userVersion = _schemaVersion;
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  static void _createTables(Database db) {
    db.execute('''
      CREATE TABLE $practiceLaps (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        round TEXT NOT NULL,
        seq INTEGER NOT NULL,
        recorded_at TEXT NOT NULL,
        lap_number INTEGER NOT NULL,
        lap_time_ms INTEGER NOT NULL,
        tyre TEXT NOT NULL,
        stint INTEGER NOT NULL,
        is_pit_lap INTEGER NOT NULL,
        is_race_lap INTEGER NOT NULL,
        race_number INTEGER,
        test_number INTEGER,
        tyre_wear_percent REAL,
        fuel_start_percent REAL NOT NULL,
        fuel_end_percent REAL NOT NULL,
        data TEXT NOT NULL
      )''');
    db.execute('CREATE INDEX practice_laps_round ON $practiceLaps (round, seq)');
    db.execute('''
      CREATE TABLE $timeTrialLaps (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        round TEXT NOT NULL,
        seq INTEGER NOT NULL,
        recorded_at TEXT NOT NULL,
        lap_time_ms INTEGER NOT NULL,
        tyre TEXT NOT NULL,
        data TEXT NOT NULL
      )''');
    db.execute('CREATE INDEX time_trial_laps_round ON $timeTrialLaps (round, seq)');
  }

  static void _createRoundBriefings(Database db) {
    db.execute('''
      CREATE TABLE $roundBriefings (
        round TEXT PRIMARY KEY,
        briefing TEXT NOT NULL,
        strategy TEXT,
        saved_at TEXT NOT NULL
      )''');
  }

  /// Runs [body] in a transaction: all of it lands, or none of it (a
  /// forced quit mid-save leaves the old rows, never half of them).
  static void _transaction(Database db, void Function() body) {
    db.execute('BEGIN');
    try {
      body();
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  // Where the lap logs lived before the database, as one JSON list each,
  // for the round saved at the time.
  static const _oldPracticeKey = 'practice_log_laps';
  static const _oldTimeTrialKey = 'time_trial_laps';
  static const _roundNameKey = 'saved_briefing_name';
  static const _oldBriefingKey = 'saved_briefing_data';
  static const _oldStrategyKey = 'saved_briefing_strategy';

  /// Moves what earlier versions kept in SharedPreferences -- the lap
  /// logs and the single saved briefing -- into the database under the
  /// round saved then, and removes the old copies (the round's name
  /// stays there, as the current round). Runs on every open; does
  /// nothing once they're gone.
  static Future<void> _importFromSharedPreferences(Database db) async {
    final prefs = await SharedPreferences.getInstance();
    final practice = prefs.getString(_oldPracticeKey);
    final timeTrial = prefs.getString(_oldTimeTrialKey);
    final briefing = prefs.getString(_oldBriefingKey);
    if (practice == null && timeTrial == null && briefing == null) return;
    final round = prefs.getString(_roundNameKey) ?? '';

    _transaction(db, () {
      if (briefing != null) {
        db.execute(
          'INSERT OR IGNORE INTO $roundBriefings (round, briefing, strategy, saved_at) VALUES (?, ?, ?, ?)',
          [round, briefing, prefs.getString(_oldStrategyKey), DateTime.now().toIso8601String()],
        );
      }
      for (final (table, raw) in [(practiceLaps, practice), (timeTrialLaps, timeTrial)]) {
        if (raw == null) continue;
        final existing = db.select('SELECT COUNT(*) AS n FROM $table WHERE round = ?', [round]).first['n'] as int;
        if (existing != 0) continue; // already imported (the removal below didn't happen)
        final maps = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        _insertAll(db, table, [
          for (final (i, map) in maps.indexed) table == practiceLaps ? practiceRow(round, i, map) : timeTrialRow(round, i, map),
        ]);
      }
    });
    for (final key in [_oldPracticeKey, _oldTimeTrialKey, _oldBriefingKey, _oldStrategyKey]) {
      await prefs.remove(key);
    }
  }

  static void _insertAll(Database db, String table, List<Map<String, Object?>> rows) {
    if (rows.isEmpty) return;
    final columns = rows.first.keys.toList();
    final statement = db.prepare(
      'INSERT INTO $table (${columns.join(', ')}) VALUES (${List.filled(columns.length, '?').join(', ')})',
    );
    try {
      for (final row in rows) {
        statement.execute([for (final c in columns) row[c]]);
      }
    } finally {
      statement.dispose();
    }
  }

  /// A practice_laps row from a PracticeLapRecord.toMap().
  static Map<String, Object?> practiceRow(String round, int seq, Map<String, dynamic> map) => {
    'round': round,
    'seq': seq,
    'recorded_at': map['recordedAt'],
    'lap_number': map['lapNumber'],
    'lap_time_ms': map['lapTimeMs'],
    'tyre': map['tireCompound'],
    'stint': map['stintNumber'] ?? 0,
    'is_pit_lap': (map['isPitLap'] as bool? ?? false) ? 1 : 0,
    'is_race_lap': (map['isRaceLap'] as bool? ?? false) ? 1 : 0,
    'race_number': map['raceNumber'],
    'test_number': map['testNumber'],
    'tyre_wear_percent': map['tireWearPercent'],
    'fuel_start_percent': map['fuelPercentAtLapStart'],
    'fuel_end_percent': map['fuelPercentAtLapEnd'],
    'data': jsonEncode(map),
  };

  /// A time_trial_laps row from a TimeTrialLap.toMap().
  static Map<String, Object?> timeTrialRow(String round, int seq, Map<String, dynamic> map) => {
    'round': round,
    'seq': seq,
    'recorded_at': map['recordedAt'],
    'lap_time_ms': map['lapTimeMs'],
    'tyre': map['tireCompound'],
    'data': jsonEncode(map),
  };

  /// Replaces [round]'s rows in [table] with [rows], in one transaction.
  static Future<void> replaceRound(String table, String round, List<Map<String, Object?>> rows) async {
    final db = await instance;
    _transaction(db, () {
      db.execute('DELETE FROM $table WHERE round = ?', [round]);
      _insertAll(db, table, rows);
    });
  }

  /// [round]'s records in [table], in saved order, as their maps.
  static Future<List<Map<String, dynamic>>> loadRound(String table, String round) async {
    final db = await instance;
    final rows = db.select('SELECT data FROM $table WHERE round = ? ORDER BY seq', [round]);
    return [for (final row in rows) jsonDecode(row['data'] as String) as Map<String, dynamic>];
  }

  /// Moves everything of round [from] -- laps and briefing -- to round
  /// [to] (a round renamed). [to]'s own briefing, if any, is replaced.
  static Future<void> renameRound(String from, String to) async {
    if (from == to) return;
    final db = await instance;
    _transaction(db, () {
      for (final table in [practiceLaps, timeTrialLaps]) {
        db.execute('UPDATE $table SET round = ? WHERE round = ?', [to, from]);
      }
      if (db.select('SELECT 1 FROM $roundBriefings WHERE round = ?', [from]).isNotEmpty) {
        db.execute('DELETE FROM $roundBriefings WHERE round = ?', [to]);
        db.execute('UPDATE $roundBriefings SET round = ? WHERE round = ?', [to, from]);
      }
    });
  }

  /// Saves [round]'s briefing and strategy (JSON), replacing any before.
  static Future<void> saveBriefing(String round, String briefing, String? strategy) async {
    final db = await instance;
    db.execute(
      'INSERT OR REPLACE INTO $roundBriefings (round, briefing, strategy, saved_at) VALUES (?, ?, ?, ?)',
      [round, briefing, strategy, DateTime.now().toIso8601String()],
    );
  }

  /// [round]'s briefing and strategy (JSON), or null if none is saved.
  static Future<(String, String?)?> loadBriefing(String round) async {
    final db = await instance;
    final rows = db.select('SELECT briefing, strategy FROM $roundBriefings WHERE round = ?', [round]);
    if (rows.isEmpty) return null;
    return (rows.first['briefing'] as String, rows.first['strategy'] as String?);
  }

  /// Each round with practice/race laps logged: its lap and stint
  /// counts, race laps, fastest non-pit lap and when it was last driven,
  /// with its saved briefing (JSON, for the track) if it has one. Most
  /// recently driven first.
  static Future<List<Map<String, Object?>>> practiceRoundSummaries() async {
    final db = await instance;
    final rows = db.select('''
      SELECT p.round AS round,
             COUNT(*) AS laps,
             COUNT(DISTINCT p.stint) AS stints,
             SUM(p.is_race_lap) AS race_laps,
             MIN(CASE WHEN p.is_pit_lap = 0 AND p.lap_time_ms > 0 THEN p.lap_time_ms END) AS best_ms,
             MAX(p.recorded_at) AS last_driven,
             b.briefing AS briefing
      FROM $practiceLaps p
      LEFT JOIN $roundBriefings b ON b.round = p.round
      GROUP BY p.round
      ORDER BY last_driven DESC''');
    return [for (final row in rows) {for (final k in row.keys) k: row[k]}];
  }

  /// Every round with a saved briefing, most recently saved first.
  static Future<List<String>> roundsWithBriefings() async {
    final db = await instance;
    return [for (final row in db.select('SELECT round FROM $roundBriefings ORDER BY saved_at DESC')) row['round'] as String];
  }

  static Future<void> deleteBriefing(String round) async {
    final db = await instance;
    db.execute('DELETE FROM $roundBriefings WHERE round = ?', [round]);
  }

  static Database? _testDb;

  /// Tests: a fresh in-memory database (see test/flutter_test_config.dart).
  @visibleForTesting
  static void useInMemoryForTests() {
    _testDb?.dispose();
    final db = _testDb = sqlite3.openInMemory();
    _migrate(db);
    _db = db;
    _opening = null;
  }

  /// Tests: runs the SharedPreferences import, as on opening.
  @visibleForTesting
  static Future<void> importFromSharedPreferencesForTests() async => _importFromSharedPreferences(await instance);
}
