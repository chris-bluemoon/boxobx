// The Race Brief saves itself: an edit is persisted shortly after it's
// made, with no Save button -- and just opening the brief saves nothing.
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:boxbox/models/fuel_prediction.dart';
import 'package:boxbox/screens/race_strategy_screen.dart';
import 'package:boxbox/services/saved_briefing_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // RaceStrategyScreen reads dotenv.env['GROQ_API_KEY'] in initState
    // (to construct RaceStrategistService) -- dotenv must be
    // initialized (even with no real .env file) or that throws.
    dotenv.testLoad(fileInput: '');
  });

  testWidgets('editing starting fuel % is saved automatically, without regenerating', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: RaceStrategyScreen(
        getCurrentFuelPrediction: () => FuelPrediction.insufficientData(),
        getPracticeLaps: () => const [],
      ),
    ));
    // Let the async track list / saved-briefing loads resolve.
    await tester.pumpAndSettle();

    final fuelField = find.widgetWithText(TextField, 'Starting fuel %');
    expect(fuelField, findsOneWidget);

    // Simulate the driver editing starting fuel from the default 100
    // down to 72, WITHOUT tapping "GENERATE STRATEGY" afterwards.
    await tester.enterText(fuelField, '72');
    await tester.pumpAndSettle();

    expect(find.text('SAVE BRIEFING FOR NEXT TIME'), findsNothing, reason: 'no Save button');
    await tester.pump(const Duration(milliseconds: 500)); // the auto-save's short wait
    await tester.pumpAndSettle();
    await RaceStrategyScreen.lastSave;

    final (_, savedBriefing, _, _, _) = await SavedBriefingStore.load();
    expect(savedBriefing, isNotNull);
    expect(
      savedBriefing!.startingFuelPercent,
      72.0,
      reason: 'The edited fuel % must be what gets saved, not a stale pre-edit value.',
    );
  });

  testWidgets('just opening the brief saves nothing', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: RaceStrategyScreen(
        getCurrentFuelPrediction: () => FuelPrediction.insufficientData(),
        getPracticeLaps: () => const [],
      ),
    ));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    final (_, savedBriefing, _, _, _) = await SavedBriefingStore.load();
    expect(savedBriefing, isNull);
  });

  test('the track list names circuits the way drivers do, sponsor after', () {
    expect(RaceStrategyScreen.trackLabel('Michelin Raceway Road Atlanta'), 'Road Atlanta (Michelin Raceway)');
    expect(RaceStrategyScreen.trackLabel('WeatherTech Raceway Laguna Seca'), 'Laguna Seca (WeatherTech Raceway)');
    expect(RaceStrategyScreen.trackLabel('Suzuka Circuit'), 'Suzuka Circuit');
  });

  testWidgets('one weather field, always there: asked for if empty, and a single slot is enough', (tester) async {
    tester.view.physicalSize = const Size(1640, 2360);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: RaceStrategyScreen(
        getCurrentFuelPrediction: () => FuelPrediction.insufficientData(),
        getPracticeLaps: () => const [],
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Wet / changeable weather'), findsNothing, reason: 'no toggle');
    final weather = find.widgetWithText(TextField, 'Race weather from the brief (e.g. C01, or R06/R05/C03/S14)');
    expect(weather, findsOneWidget);

    await tester.ensureVisible(find.text('GENERATE STRATEGY'));
    await tester.tap(find.text('GENERATE STRATEGY'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter the race weather'), findsOneWidget);

    await tester.enterText(weather, 'c01');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await RaceStrategyScreen.lastSave;
    final (_, saved, _, _, _) = await SavedBriefingStore.load();
    expect(saved!.weatherSlots, 'C01');
    expect(saved.wetOrChangeableWeather, isFalse);
  });

  testWidgets('only the slicks to tick, at least one stays ticked, and Inters and Wets are always in', (tester) async {
    tester.view.physicalSize = const Size(1640, 2360);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: RaceStrategyScreen(
        getCurrentFuelPrediction: () => FuelPrediction.insufficientData(),
        getPracticeLaps: () => const [],
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilterChip, 'Intermediate'), findsNothing);
    expect(find.widgetWithText(FilterChip, 'Heavy Wet'), findsNothing);

    // Hard and Medium start ticked: untick both -- Medium, the last, stays.
    for (final c in ['Racing Hard', 'Racing Medium']) {
      await tester.ensureVisible(find.widgetWithText(FilterChip, c));
      await tester.tap(find.widgetWithText(FilterChip, c));
      await tester.pumpAndSettle();
    }
    expect(tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'Racing Medium')).selected, isTrue);
    expect(tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'Racing Hard')).selected, isFalse);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await RaceStrategyScreen.lastSave;
    final (_, saved, _, _, _) = await SavedBriefingStore.load();
    expect(saved!.availableTireCompounds, ['Racing Medium', 'Intermediate', 'Heavy Wet']);
  });

  testWidgets('generating again shows what changed and why', (tester) async {
    tester.view.physicalSize = const Size(1640, 2360);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: RaceStrategyScreen(
        getCurrentFuelPrediction: () => FuelPrediction.insufficientData(),
        getPracticeLaps: () => const [],
      ),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Race weather from the brief (e.g. C01, or R06/R05/C03/S14)'),
      'R06/R05/C03/S14/S04/R03/R04/R05',
    );
    await tester.pumpAndSettle();
    Future<void> generate() async {
      await tester.ensureVisible(find.text('GENERATE STRATEGY'));
      await tester.tap(find.text('GENERATE STRATEGY'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
    }

    await generate();
    expect(find.text('Strategy updated'), findsNothing, reason: 'nothing to compare the first time');
    await generate();
    expect(find.text('Strategy unchanged'), findsOneWidget);
    expect(find.textContaining('community tyre guide'), findsNWidgets(2), reason: 'the why: one line per wet spell');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  });
}
