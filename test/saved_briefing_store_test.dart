// Validates SavedBriefingStore's single-slot save/load/clear round trip
// against real SharedPreferences plugin bindings (mocked storage via
// setMockInitialValues, same approach the shared_preferences package
// itself recommends for testing). Uses flutter_test (not a standalone
// dart script) because SharedPreferences needs Flutter plugin bindings
// to initialize.
//
// Run with: flutter test test/saved_briefing_store_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/models/race_strategy.dart';
import 'package:boxbox/services/saved_briefing_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  final briefing = RaceBriefing(
    trackName: 'Suzuka Circuit',
    totalLaps: 32,
    startingFuelPercent: 100,
    fuelConsumptionMultiplier: 3.0,
    availableTireCompounds: const ['Racing Hard'],
    mandatoryPitStopCount: 1,
  );

  const strategy = RaceStrategy(
    pitStops: [PlannedPitStop(lap: 16, tireCompound: 'Racing Hard', reasoning: 'Fuel window')],
    startingTireCompound: 'Racing Hard',
    summary: 'One-stop strategy.',
    assumedPercentPerLap: 9.0,
  );

  test('load() returns all nulls when nothing has been saved yet', () async {
    final (name, loadedBriefing, loadedStrategy, _, _) = await SavedBriefingStore.load();
    expect(name, isNull);
    expect(loadedBriefing, isNull);
    expect(loadedStrategy, isNull);
  });

  test('save() then load() round-trips the name, briefing, and strategy', () async {
    await SavedBriefingStore.save(name: 'Round 5', briefing: briefing, strategy: strategy);

    final (name, loadedBriefing, loadedStrategy, _, _) = await SavedBriefingStore.load();

    expect(name, 'Round 5');
    expect(loadedBriefing, isNotNull);
    expect(loadedBriefing!.trackName, 'Suzuka Circuit');
    expect(loadedBriefing.totalLaps, 32);
    expect(loadedBriefing.fuelConsumptionMultiplier, 3.0);
    expect(loadedBriefing.availableTireCompounds, ['Racing Hard']);
    expect(loadedBriefing.mandatoryPitStopCount, 1);

    expect(loadedStrategy, isNotNull);
    expect(loadedStrategy!.startingTireCompound, 'Racing Hard');
    expect(loadedStrategy.pitStops.single.lap, 16);
  });

  test('save() without a strategy round-trips the briefing with a null strategy', () async {
    await SavedBriefingStore.save(name: 'Round 6', briefing: briefing);

    final (name, loadedBriefing, loadedStrategy, _, _) = await SavedBriefingStore.load();

    expect(name, 'Round 6');
    expect(loadedBriefing, isNotNull);
    expect(loadedStrategy, isNull);
  });

  test('saving again overwrites the single slot (only one round is ever kept)', () async {
    await SavedBriefingStore.save(name: 'Round 5', briefing: briefing, strategy: strategy);
    final laterBriefing = RaceBriefing(
      trackName: 'Fuji Speedway',
      totalLaps: 20,
      startingFuelPercent: 100,
      availableTireCompounds: const ['Racing Medium'],
    );
    await SavedBriefingStore.save(name: 'Round 6', briefing: laterBriefing);

    final (name, loadedBriefing, loadedStrategy, _, _) = await SavedBriefingStore.load();

    expect(name, 'Round 6');
    expect(loadedBriefing!.trackName, 'Fuji Speedway');
    expect(loadedStrategy, isNull);
  });

  test('clear() removes the saved briefing entirely', () async {
    await SavedBriefingStore.save(name: 'Round 5', briefing: briefing, strategy: strategy);
    await SavedBriefingStore.clear();

    final (name, loadedBriefing, loadedStrategy, _, _) = await SavedBriefingStore.load();

    expect(name, isNull);
    expect(loadedBriefing, isNull);
    expect(loadedStrategy, isNull);
  });
}
