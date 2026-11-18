import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:boxbox/models/fuel_prediction.dart';
import 'package:boxbox/models/league_calendar.dart';
import 'package:boxbox/screens/race_strategy_screen.dart';
import 'package:boxbox/services/saved_briefing_store.dart';

void main() {
  test('the Season 12 calendar: nine rounds, each on a track the app knows', () {
    expect(LeagueCalendar.rounds.map((r) => r.name), [
      'Round 1 - Road Atlanta',
      'Round 2 - Lago Maggiore West',
      'Round 3 - Mount Panorama',
      'Round 4 - Alsace Village (Reverse)',
      'Round 5 - Nürburgring Sprint',
      'Round 6 - Sainte-Croix C',
      'Round 7 - Yas Marina',
      'Round 8 - Sportsland Sugo',
      'Season Finale - Watkins Glen Long',
    ]);
    final known = (jsonDecode(File('assets/config/all_tracks.json').readAsStringSync())['tracks'] as List)
        .map((t) => t['name'] as String)
        .toSet();
    for (final round in LeagueCalendar.rounds) {
      expect(known, contains(round.gt7Track), reason: round.name);
    }
    expect(LeagueCalendar.byName('Round 5 - Nürburgring Sprint')!.details, '17/11 – 19/11 · variable weather');
    expect(LeagueCalendar.byName('Round 8 - Sportsland Sugo')!.featureRace, isTrue);
    expect(LeagueCalendar.byName('Season Finale - Watkins Glen Long')!.raceLengthMinutes, 90);
  });

  testWidgets('picking a round names the briefing and fills in its track and weather', (tester) async {
    SharedPreferences.setMockInitialValues({});
    dotenv.testLoad(fileInput: '');
    tester.view.physicalSize = const Size(1640, 2360);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: RaceStrategyScreen(
          getCurrentFuelPrediction: () => FuelPrediction.insufficientData(),
          getPracticeLaps: () => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Round 1 - Road Atlanta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Round 5 - Nürburgring Sprint').last);
    await tester.pumpAndSettle();
    expect(find.text('17/11 – 19/11 · variable weather'), findsOneWidget);
    expect(find.text('Nürburgring Sprint'), findsWidgets, reason: 'track pre-selected');

    // Saved automatically -- no Save button.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await RaceStrategyScreen.lastSave;

    final (name, briefing, _, _, _) = await SavedBriefingStore.load();
    expect(name, 'Round 5 - Nürburgring Sprint');
    expect(briefing!.trackName, 'Nürburgring Sprint');
    expect(briefing.weatherSlots, '', reason: 'the weather comes from the weekly brief, not the calendar');
  });

  test("renaming 'Round 5' to its calendar name keeps the round's data; a different round still clears it", () {
    expect(SavedBriefingStore.isSameRound('Round 5', 'Round 5 - Nürburgring Sprint'), isTrue);
    expect(SavedBriefingStore.isSameRound('Round 5 - Nürburgring Sprint', 'Round 5'), isTrue);
    expect(SavedBriefingStore.isSameRound('Round 5', 'Round 5'), isTrue);
    expect(SavedBriefingStore.isSameRound('Round 5', 'Round 6 - Sainte-Croix C'), isFalse);
    expect(SavedBriefingStore.isSameRound('Round 1', 'Round 10 - Somewhere'), isFalse);
  });
}
