// Validates PitStopTimeStore's save/load/average/clear behavior, and
// its interaction with SavedBriefingStore (measured pit-stop times
// persist across edits to the SAME round, cleared on a NEW round).
//
// Run with: flutter test test/pit_stop_time_store_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:boxbox/models/pit_stop_time_record.dart';
import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/services/pit_stop_time_store.dart';
import 'package:boxbox/services/saved_briefing_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  final record1 = PitStopTimeRecord(
    totalTimeLossSeconds: 22.0,
    tireCompoundFitted: 'Racing Hard',
    refuelRateLitersPerSecond: 8.0,
    recordedAt: DateTime(2026, 1, 1, 12),
  );
  final record2 = PitStopTimeRecord(
    totalTimeLossSeconds: 24.0,
    tireCompoundFitted: 'Racing Medium',
    refuelRateLitersPerSecond: 8.0,
    recordedAt: DateTime(2026, 1, 1, 12, 10),
  );

  final briefing = RaceBriefing(
    trackName: 'Suzuka Circuit',
    totalLaps: 20,
    startingFuelPercent: 100,
    availableTireCompounds: const ['Racing Hard'],
  );

  test('load() returns an empty list when nothing has been saved yet', () async {
    final records = await PitStopTimeStore.load();
    expect(records, isEmpty);
  });

  test('addRecord() appends to the existing list rather than overwriting it', () async {
    await PitStopTimeStore.addRecord(record1);
    await PitStopTimeStore.addRecord(record2);

    final records = await PitStopTimeStore.load();
    expect(records.length, 2);
    expect(records[0].totalTimeLossSeconds, 22.0);
    expect(records[1].totalTimeLossSeconds, 24.0);
  });

  test('averageTimeLossSeconds computes the correct average', () {
    expect(PitStopTimeStore.averageTimeLossSeconds([record1, record2]), 23.0);
  });

  test('averageTimeLossSeconds returns null for an empty list', () {
    expect(PitStopTimeStore.averageTimeLossSeconds([]), isNull);
  });

  test('clear() removes all records', () async {
    await PitStopTimeStore.addRecord(record1);
    await PitStopTimeStore.clear();

    final records = await PitStopTimeStore.load();
    expect(records, isEmpty);
  });

  test('saving edits to the SAME round preserves logged pit-stop times', () async {
    await SavedBriefingStore.save(name: 'Round 5', briefing: briefing);
    await PitStopTimeStore.addRecord(record1);

    await SavedBriefingStore.save(name: 'Round 5', briefing: briefing);

    final records = await PitStopTimeStore.load();
    expect(records.length, 1);
  });

  test('saving under a DIFFERENT round name clears logged pit-stop times', () async {
    await SavedBriefingStore.save(name: 'Round 5', briefing: briefing);
    await PitStopTimeStore.addRecord(record1);

    await SavedBriefingStore.save(name: 'Round 6', briefing: briefing);

    final records = await PitStopTimeStore.load();
    expect(records, isEmpty);
  });
}
