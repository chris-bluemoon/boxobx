// Validates PracticeLogStore's save/load/clear round trip against
// mocked SharedPreferences, and SavedBriefingStore's interaction with
// it (practice laps persist indefinitely across saves of the SAME
// round, but are cleared when a genuinely NEW round is saved).
//
// Run with: flutter test test/practice_log_store_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/services/practice_log_store.dart';
import 'package:boxbox/services/saved_briefing_store.dart';

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

  test('saving under a DIFFERENT round name clears the old practice log', () async {
    await SavedBriefingStore.save(name: 'Round 5', briefing: briefing);
    await PracticeLogStore.save([lap1, lap2]);

    await SavedBriefingStore.save(name: 'Round 6', briefing: briefing);

    final laps = await PracticeLogStore.load();
    expect(laps, isEmpty);
  });
}
