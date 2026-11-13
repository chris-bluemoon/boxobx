import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:boxbox/models/championship_standing.dart';
import 'package:boxbox/services/championship_standings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const standings = [
    ChampionshipStanding(driverName: 'Salty-067', totalPoints: 71, roundPoints: 0),
    ChampionshipStanding(driverName: 'Chuck_E82', totalPoints: 66, roundPoints: 35),
    ChampionshipStanding(driverName: 'Willy-SwerveX', totalPoints: 66, roundPoints: 33),
  ];

  test('load() returns an empty list when nothing has been saved yet', () async {
    expect(await ChampionshipStandingsStore.load(), isEmpty);
  });

  test('save() then load() round-trips every standing exactly', () async {
    await ChampionshipStandingsStore.save(standings);
    final loaded = await ChampionshipStandingsStore.load();

    expect(loaded, hasLength(3));
    expect(loaded[0].driverName, 'Salty-067');
    expect(loaded[0].totalPoints, 71);
    expect(loaded[1].roundPoints, 35);
  });

  test('sortedByPosition() orders by totalPoints descending', () {
    final sorted = ChampionshipStandingsStore.sortedByPosition(standings);
    expect(sorted.map((s) => s.driverName).toList(), ['Salty-067', 'Chuck_E82', 'Willy-SwerveX']);
  });

  test('sortedByPosition() breaks a tie by preserving input order (stable sort)', () {
    // Chuck_E82 and Willy-SwerveX are tied at 66 in the real standings
    // table -- a stable sort must not arbitrarily reorder them.
    final sorted = ChampionshipStandingsStore.sortedByPosition(standings);
    expect(sorted[1].driverName, 'Chuck_E82');
    expect(sorted[2].driverName, 'Willy-SwerveX');
  });

  test('positionOf() returns the 1-indexed derived position', () {
    expect(ChampionshipStandingsStore.positionOf('Salty-067', standings), 1);
    expect(ChampionshipStandingsStore.positionOf('Chuck_E82', standings), 2);
    expect(ChampionshipStandingsStore.positionOf('Willy-SwerveX', standings), 3);
  });

  test('positionOf() returns null for a driver with no standings entry', () {
    expect(ChampionshipStandingsStore.positionOf('NotInTheList', standings), isNull);
  });

  test('pointsGapTo() returns the signed points difference', () {
    expect(ChampionshipStandingsStore.pointsGapTo('Salty-067', 'Chuck_E82', standings), 5);
    expect(ChampionshipStandingsStore.pointsGapTo('Chuck_E82', 'Salty-067', standings), -5);
    expect(ChampionshipStandingsStore.pointsGapTo('Chuck_E82', 'Willy-SwerveX', standings), 0);
  });

  test('pointsGapTo() returns null if either driver has no entry', () {
    expect(ChampionshipStandingsStore.pointsGapTo('Salty-067', 'NotInTheList', standings), isNull);
  });

  test('clear() removes the saved standings', () async {
    await ChampionshipStandingsStore.save(standings);
    await ChampionshipStandingsStore.clear();

    expect(await ChampionshipStandingsStore.load(), isEmpty);
  });
}
