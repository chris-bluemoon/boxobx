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

  testWidgets('shows the first and last roster drivers as rows (scrollable list)', (tester) async {
    // ListView.builder only renders items currently within the
    // viewport -- scrolling to the end confirms the full roster is
    // wired in as the itemCount, without needing every single one of
    // the 18 entries simultaneously on screen (which a finite test
    // viewport can't show at once anyway).
    await tester.pumpWidget(const MaterialApp(home: ChampionshipScreen()));
    await tester.pumpAndSettle();

    expect(find.text(leagueRoster.first), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text(leagueRoster.last),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text(leagueRoster.last), findsOneWidget);
  });

  testWidgets('entering totals and saving persists standings + derives position', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChampionshipScreen()));
    await tester.pumpAndSettle();

    final firstDriver = leagueRoster.first;
    // Locate the Total field for the first row by its position within
    // that row (2nd TextField: Rnd field first, Total field second).
    final rowFinder = find.ancestor(of: find.text(firstDriver), matching: find.byType(Row));
    final totalTextField = find.descendant(of: rowFinder, matching: find.byType(TextField)).at(1);

    await tester.enterText(totalTextField, '71');
    await tester.pumpAndSettle();

    expect(find.text('P1'), findsOneWidget);

    final saveButton = find.widgetWithText(ElevatedButton, 'SAVE STANDINGS');
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    final saved = await ChampionshipStandingsStore.load();
    expect(saved, hasLength(1));
    expect(saved.single.driverName, firstDriver);
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
