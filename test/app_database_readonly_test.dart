// A database put back from a backup that the app can read but not write
// is copied into a file the app owns, data and all.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:boxbox/services/app_database.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('boxbox_db'));
  tearDown(() {
    Process.runSync('chmod', ['-R', 'u+w', tmp.path]);
    tmp.deleteSync(recursive: true);
  });

  String restored(String dir) {
    Directory(dir).createSync(recursive: true);
    final path = p.join(dir, 'boxbox.db');
    final db = sqlite3.open(path)
      ..execute('CREATE TABLE laps (n INTEGER)')
      ..execute('INSERT INTO laps VALUES (1), (2)');
    db.dispose();
    Process.runSync('chmod', ['444', path]);
    return path;
  }

  test('a read-only file: replaced in place by a writable copy', () {
    final path = restored(p.join(tmp.path, 'Application Support'));
    final db = AppDatabase.openWritable(path, fallbackDir: p.join(tmp.path, 'BoxboxData'));
    db.execute('INSERT INTO laps VALUES (3)');
    expect(db.select('SELECT count(*) c FROM laps').first['c'], 3);
    db.dispose();
    expect(Directory(p.join(tmp.path, 'BoxboxData')).existsSync(), isFalse);
  });

  test('a read-only folder too: the copy goes in the fallback folder, which is used from then on', () {
    final dir = p.join(tmp.path, 'Application Support');
    final path = restored(dir);
    Process.runSync('chmod', ['555', dir]);
    final fallback = p.join(tmp.path, 'BoxboxData');
    final db = AppDatabase.openWritable(path, fallbackDir: fallback);
    db.execute('INSERT INTO laps VALUES (3)');
    db.dispose();
    final again = AppDatabase.openWritable(path, fallbackDir: fallback);
    expect(again.select('SELECT count(*) c FROM laps').first['c'], 3);
    again.dispose();
  });
}
