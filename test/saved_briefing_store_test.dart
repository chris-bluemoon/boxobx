// Validates SavedBriefingStore: the current round (in mocked
// SharedPreferences) and each round's briefing and strategy (in the app
// database, in memory in tests) -- save/load/clear, switching rounds,
// renames, and importing the single briefing earlier versions saved.
//
// Run with: flutter test test/saved_briefing_store_test.dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/models/race_strategy.dart';
import 'package:boxbox/services/app_database.dart';
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

  test('each round keeps its own briefing; saving another round makes it current', () async {
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

    final round5 = await SavedBriefingStore.briefingFor('Round 5');
    expect(round5!.$1.trackName, 'Suzuka Circuit');
    expect(round5.$2!.summary, 'One-stop strategy.');
    expect(await SavedBriefingStore.savedRounds(), ['Round 6', 'Round 5']);
  });

  test('selecting a round switches to it, with its own briefing or none', () async {
    await SavedBriefingStore.save(name: 'Round 5', briefing: briefing, strategy: strategy);

    await SavedBriefingStore.selectRound('Round 6 - Sainte-Croix C');
    var (name, loadedBriefing, _, _, _) = await SavedBriefingStore.load();
    expect(name, 'Round 6 - Sainte-Croix C');
    expect(loadedBriefing, isNull);
    expect(await SavedBriefingStore.currentRound(), 'Round 6 - Sainte-Croix C');

    await SavedBriefingStore.selectRound('Round 5');
    (name, loadedBriefing, _, _, _) = await SavedBriefingStore.load();
    expect(loadedBriefing!.trackName, 'Suzuka Circuit');
  });

  test("renaming the same round takes its briefing with it", () async {
    await SavedBriefingStore.save(name: 'Round 5', briefing: briefing, strategy: strategy);
    await SavedBriefingStore.save(name: 'Round 5 - Nürburgring Sprint', briefing: briefing);
    expect(await SavedBriefingStore.savedRounds(), ['Round 5 - Nürburgring Sprint']);
  });

  test('the single briefing earlier versions saved is imported under its round', () async {
    SharedPreferences.setMockInitialValues({
      'saved_briefing_name': 'Round 4',
      'saved_briefing_data': jsonEncode(briefing.toMap()),
      'saved_briefing_strategy': jsonEncode(strategy.toMap()),
    });
    await AppDatabase.importFromSharedPreferencesForTests();

    final (name, loadedBriefing, loadedStrategy, _, _) = await SavedBriefingStore.load();
    expect(name, 'Round 4');
    expect(loadedBriefing!.trackName, 'Suzuka Circuit');
    expect(loadedStrategy!.pitStops.single.lap, 16);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('saved_briefing_data'), isNull);
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
