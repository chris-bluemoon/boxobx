// Regression test for the reported bug: editing the Race Strategy form
// (e.g. starting fuel %) and tapping "SAVE BRIEFING FOR NEXT TIME"
// WITHOUT re-generating a strategy first must still persist the edit.
// Previously _saveBriefing() saved a stale _briefing object that was
// only ever updated inside _generateStrategy(), so edits made after
// generating (or after loading a previously-saved briefing) were
// silently dropped on save.
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:boxbox/models/fuel_prediction.dart';
import 'package:boxbox/models/tire_wear_estimate.dart';
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

  testWidgets('editing starting fuel % and saving (without regenerating) persists the edit', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: RaceStrategyScreen(
        getCurrentFuelPrediction: () => FuelPrediction.insufficientData(),
        getCurrentTireWearEstimate: () => TireWearEstimate.insufficientData(),
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

    final saveButton = find.widgetWithText(OutlinedButton, 'SAVE BRIEFING FOR NEXT TIME');
    expect(saveButton, findsOneWidget);
    await tester.scrollUntilVisible(saveButton, 500, scrollable: find.byType(Scrollable).first);
    await tester.tap(saveButton, warnIfMissed: false);
    await tester.pumpAndSettle();

    final (_, savedBriefing, _, _, _) = await SavedBriefingStore.load();
    expect(savedBriefing, isNotNull);
    expect(
      savedBriefing!.startingFuelPercent,
      72.0,
      reason: 'The edited fuel % must be what gets saved, not a stale pre-edit value.',
    );
  });
}
