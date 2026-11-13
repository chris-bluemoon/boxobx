import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:boxbox/screens/championship_screen.dart';
import 'package:boxbox/services/championship_standings_store.dart';
import 'package:boxbox/services/league_roster.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows the first roster driver as a row, with header columns R1-R9', (tester) async {
    // ListView.builder only renders items currently within the
    // viewport -- this just confirms the table itself is wired up
    // correctly (header columns + at least the first roster entry),
    // rather than needing every one of the 18 entries simultaneously
    // on screen (which a finite test viewport can't show anyway, and
    // reliably scrolling a nested horizontal+vertical scroll setup in
    // a widget test is brittle).
    await tester.pumpWidget(const MaterialApp(home: ChampionshipScreen()));
    await tester.pumpAndSettle();

    expect(find.text(leagueRoster.first), findsOneWidget);
    expect(find.text('DRIVER'), findsOneWidget);
    for (var round = 1; round <= 9; round++) {
      expect(find.text('R$round'), findsOneWidget);
    }
    expect(find.text('DROP'), findsOneWidget);
    expect(find.text('TOTAL'), findsOneWidget);
  });

  testWidgets('entering round scores and saving persists standings + derives position + total', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChampionshipScreen()));
    await tester.pumpAndSettle();

    final firstDriver = leagueRoster.first;
    // Locate this driver's row, then its first round-score TextField
    // (the row is: name text + 9 round fields + 1 drop-points field,
    // so the first TextField in the row is Round 1).
    final rowFinder = find.ancestor(of: find.text(firstDriver), matching: find.byType(Row)).first;
    final round1Field = find.descendant(of: rowFinder, matching: find.byType(TextField)).at(0);

    await tester.enterText(round1Field, '71');
    await tester.pumpAndSettle();

    expect(find.text('P1'), findsOneWidget);
    expect(find.text('71'), findsWidgets); // the derived TOTAL column shows 71 too (single round, no drop)

    final saveButton = find.widgetWithText(ElevatedButton, 'SAVE STANDINGS');
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    final saved = await ChampionshipStandingsStore.load();
    expect(saved, hasLength(1));
    expect(saved.single.driverName, firstDriver);
    expect(saved.single.roundPoints[0], 71);
    expect(saved.single.totalPoints, 71);
  });

  testWidgets('tapping a driver row does nothing -- no rival selection UI on this screen', (tester) async {
    // Regression-shaped test for the opposite requirement now: rival
    // selection/highlighting was intentionally REMOVED from this
    // screen (which drivers Gunther tracks on-track is now a
    // --rival-names flag on the laptop relay, not picked here). Tapping
    // a driver's name should have no visible effect at all.
    await tester.pumpWidget(const MaterialApp(home: ChampionshipScreen()));
    await tester.pumpAndSettle();

    final firstDriver = leagueRoster.first;
    final containerBefore = tester.widget<Container>(
      find.ancestor(of: find.text(firstDriver), matching: find.byType(Container)).first,
    );

    await tester.tap(find.text(firstDriver));
    await tester.pumpAndSettle();

    final containerAfter = tester.widget<Container>(
      find.ancestor(of: find.text(firstDriver), matching: find.byType(Container)).first,
    );
    expect(containerAfter.decoration, containerBefore.decoration);
  });
}
