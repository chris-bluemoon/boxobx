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

  /// The row's own Container decoration (amber tint + border) is the
  /// ONLY indicator of rival selection -- there is deliberately no
  /// separate star/checkbox control (see championship_screen.dart's
  /// _driverRow). This reads the Container immediately wrapping a
  /// given driver's row to check whether it's currently highlighted as
  /// selected.
  bool isHighlightedAsRival(WidgetTester tester, String driver) {
    final container = tester.widget<Container>(
      find.ancestor(of: find.text(driver), matching: find.byType(Container)).first,
    );
    final decoration = container.decoration as BoxDecoration;
    return decoration.border == Border.all(color: Colors.amberAccent, width: 2);
  }

  testWidgets('tapping the driver name/row toggles its highlight on and off', (tester) async {
    // Regression test: previously only a small star IconButton
    // responded to a tap at all -- tapping the driver's name or
    // anywhere else on the row did nothing, which wasn't discoverable
    // (reported live: "why can't I tap the drivers"). The fix removed
    // the star entirely in favor of the row's own highlight being both
    // the tap target AND the selection indicator.
    await tester.pumpWidget(const MaterialApp(home: ChampionshipScreen()));
    await tester.pumpAndSettle();

    final firstDriver = leagueRoster.first;
    expect(isHighlightedAsRival(tester, firstDriver), isFalse);

    await tester.tap(find.text(firstDriver));
    await tester.pumpAndSettle();
    expect(isHighlightedAsRival(tester, firstDriver), isTrue);

    // Tapping it again toggles it back off.
    await tester.tap(find.text(firstDriver));
    await tester.pumpAndSettle();
    expect(isHighlightedAsRival(tester, firstDriver), isFalse);
  });

  testWidgets('selecting a 3rd rival shows a warning and does not highlight it', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChampionshipScreen()));
    await tester.pumpAndSettle();

    final first = leagueRoster[0];
    final second = leagueRoster[1];
    final third = leagueRoster[2];

    await tester.tap(find.text(first));
    await tester.pumpAndSettle();
    await tester.tap(find.text(second));
    await tester.pumpAndSettle();
    await tester.tap(find.text(third));
    await tester.pumpAndSettle();

    expect(isHighlightedAsRival(tester, first), isTrue);
    expect(isHighlightedAsRival(tester, second), isTrue);
    expect(isHighlightedAsRival(tester, third), isFalse);
    expect(find.textContaining('Only 2 rivals'), findsOneWidget);
  });
}
