// Validates PracticeLogStore's save/load/clear round trip against the
// app database (in memory in tests), and SavedBriefingStore's
// interaction with it: laps belong to a round -- kept across saves of
// the SAME round, a fresh log for a NEW round with the old round's laps
// kept as history -- and laps saved by earlier versions in
// SharedPreferences are imported.
//
// Run with: flutter test test/practice_log_store_test.dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/services/app_database.dart';
import 'package:boxbox/services/practice_log_store.dart';
import 'package:boxbox/services/saved_briefing_store.dart';
import 'package:boxbox/services/time_trial_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  final lap1 = PracticeLapRecord(
    lapNumber: 1,
    lapTimeMs: 90000,
    tireCompound: 'Racing Hard',
    fuelPercentAtLapStart: 100,
    fuelPercentAtLapEnd: 97,
    recordedAt: DateTime(2026, 1, 1, 12),
  );
  final lap2 = PracticeLapRecord(
    lapNumber: 2,
    lapTimeMs: 89500,
    tireCompound: 'Racing Hard',
    fuelPercentAtLapStart: 97,
    fuelPercentAtLapEnd: 94,
    recordedAt: DateTime(2026, 1, 1, 12, 2),
  );

  final briefing = RaceBriefing(
    trackName: 'Suzuka Circuit',
    totalLaps: 20,
    startingFuelPercent: 100,
    availableTireCompounds: const ['Racing Hard'],
  );

  test('load() returns an empty list when nothing has been saved yet', () async {
    final laps = await PracticeLogStore.load();
    expect(laps, isEmpty);
  });

  test('save() then load() round-trips every lap exactly', () async {
    await PracticeLogStore.save([lap1, lap2]);

    final laps = await PracticeLogStore.load();

    expect(laps.length, 2);
    expect(laps[0].lapTimeMs, 90000);
    expect(laps[0].tireCompound, 'Racing Hard');
    expect(laps[1].fuelPercentAtLapEnd, 94);
  });

  test('clear() removes the log entirely', () async {
    await PracticeLogStore.save([lap1, lap2]);
    await PracticeLogStore.clear();

    final laps = await PracticeLogStore.load();
    expect(laps, isEmpty);
  });

  test('saving edits to the SAME round preserves the practice log', () async {
    await SavedBriefingStore.save(name: 'Round 5', briefing: briefing);
    await PracticeLogStore.save([lap1, lap2]);

    // Re-saving the SAME round name (simulating a minor form edit)
    // must NOT wipe the practice log -- that data took real driving
    // effort and isn't invalidated by tweaking a field.
    await SavedBriefingStore.save(name: 'Round 5', briefing: briefing);

    final laps = await PracticeLogStore.load();
    expect(laps.length, 2);
  });

  test('a DIFFERENT round starts an empty log; the old round keeps its laps', () async {
    await SavedBriefingStore.save(name: 'Round 5', briefing: briefing);
    await PracticeLogStore.save([lap1, lap2]);

    await SavedBriefingStore.save(name: 'Round 6', briefing: briefing);
    expect(await PracticeLogStore.load(), isEmpty);
    await PracticeLogStore.save([lap1]);

    await SavedBriefingStore.save(name: 'Round 5', briefing: briefing);
    expect((await PracticeLogStore.load()).map((l) => l.lapTimeMs), [90000, 89500]);
  });

  test('laps logged before any round is saved go with the first round, and follow a rename', () async {
    await PracticeLogStore.save([lap1, lap2]);
    await SavedBriefingStore.save(name: 'Round 5', briefing: briefing);
    expect(await PracticeLogStore.load(), hasLength(2));

    await SavedBriefingStore.save(name: 'Round 5 - Nürburgring Sprint', briefing: briefing);
    expect(await PracticeLogStore.load(), hasLength(2));
  });

  test('clearing the log clears only the current round', () async {
    await SavedBriefingStore.save(name: 'Round 5', briefing: briefing);
    await PracticeLogStore.save([lap1, lap2]);
    await SavedBriefingStore.save(name: 'Round 6', briefing: briefing);
    await PracticeLogStore.save([lap1]);
    await PracticeLogStore.clear();

    await SavedBriefingStore.save(name: 'Round 5', briefing: briefing);
    expect(await PracticeLogStore.load(), hasLength(2));
  });

  test('every field survives the database, in order', () async {
    final full = PracticeLapRecord(
      lapNumber: 7,
      lapTimeMs: 91234,
      tireCompound: 'Racing Soft',
      fuelPercentAtLapStart: 64.5,
      fuelPercentAtLapEnd: 61.25,
      tireWearPercent: 72,
      recordedAt: DateTime(2026, 11, 14, 20, 1, 2),
      isPitLap: true,
      stintNumber: 3,
      isRaceLap: true,
      testNumber: 2,
      testTargetReached: true,
      raceNumber: 1,
      position: 4,
      sectorsMs: const [30000, 31000, 30234],
    );
    await PracticeLogStore.save([lap2, full, lap1]);
    final laps = await PracticeLogStore.load();
    expect(laps.map((l) => l.lapNumber), [2, 7, 1]);
    expect(laps[1].toMap(), full.toMap());
  });

  test('laps saved by earlier versions are moved into the database, once', () async {
    SharedPreferences.setMockInitialValues({
      'saved_briefing_name': 'Round 5',
      'practice_log_laps': jsonEncode([lap1.toMap(), lap2.toMap()]),
      'time_trial_laps': jsonEncode([
        {'lapTimeMs': 89950, 'tireCompound': 'Racing Soft', 'recordedAt': DateTime(2026).toIso8601String()},
      ]),
    });
    await AppDatabase.importFromSharedPreferencesForTests();
    await AppDatabase.importFromSharedPreferencesForTests();

    expect(await PracticeLogStore.load(), hasLength(2));
    expect(await TimeTrialStore.load(), hasLength(1));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('practice_log_laps'), isNull);
    expect(prefs.getString('time_trial_laps'), isNull);
  });
}
