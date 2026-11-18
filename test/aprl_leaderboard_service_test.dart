// The APRL tab's standings, totalled from the leaderboard's results feed
// the way the leaderboard site does.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:boxbox/services/aprl_leaderboard_service.dart';
import 'package:boxbox/services/championship_standings_store.dart';

Map<String, dynamic> result(String driver, String round, int place, int points,
        {String series = 'Development Series (GT3 Clubman)', String raceTime = '0:40:00.000'}) =>
    {'series': series, 'round': round, 'driver': driver, 'place': place, 'points': points, 'raceTime': raceTime};

Map<String, dynamic> feed(List<Map<String, dynamic>> results) => {
  'ok': true,
  'data': {'results': results},
};

void main() {
  test('points per round, the lowest round dropped, missed rounds counted as 0 for the drop', () {
    final standings = AprlLeaderboardService.standingsFrom(feed([
      result('Willy-SwerveX', 'R1 CB', 2, 33),
      result('Willy-SwerveX', 'R2 CB', 16, 17),
      result('Willy-SwerveX', 'R3 CB', 2, 33),
      result('Salty-067', 'R1 CB', 1, 35),
      result('Salty-067', 'R2 CB', 1, 36),
      // Salty missed R3: that 0 is the round dropped.
      result('Pro driver', 'R1 PS', 1, 35, series: 'Pro Series (GT3 Pro)'),
    ]));
    expect([for (final s in standings) s.driverName], ['Salty-067', 'Willy-SwerveX']);
    final salty = standings.first;
    expect(salty.roundPoints.take(4), [35, 36, null, null]);
    expect(salty.dropPoints, 0);
    expect(salty.totalPoints, 71);
    final willy = standings.last;
    expect(willy.dropPoints, 17);
    expect(willy.totalPoints, 66);
    expect(willy.roundsRaced, 3);
  });

  test('no drop after one round', () {
    final standings = AprlLeaderboardService.standingsFrom(feed([result('Willy-SwerveX', 'R1 CB', 2, 33)]));
    expect(standings.single.dropPoints, 0);
    expect(standings.single.totalPoints, 33);
  });

  test('our series is where our latest result is', () {
    final results = [
      result('Willy-SwerveX', 'R1 FS', 1, 35, series: 'Development Series (GT3 Foundation)'),
      result('Willy-SwerveX', 'R2 CB', 4, 29),
    ];
    expect(AprlLeaderboardService.seriesOf(results), 'Development Series (GT3 Clubman)');
    expect(AprlLeaderboardService.seriesOf(const []), AprlLeaderboardService.defaultSeries);
  });

  test('one spelling per driver, and ties go on countback (a DNF place does not count)', () {
    final standings = AprlLeaderboardService.standingsFrom(feed([
      result('Chuck_E82', 'R1 CB', 2, 30),
      result('Chuck-E82', 'R2 CB', 1, 30),
      result('Chuck_E82', 'R3 CB', 3, 30),
      result('Willy-SwerveX', 'R1 CB', 1, 30, raceTime: 'DNF'),
      result('Willy-SwerveX', 'R2 CB', 2, 30),
      result('Willy-SwerveX', 'R3 CB', 3, 30),
    ]));
    expect([for (final s in standings) s.driverName], ['Chuck_E82', 'Willy-SwerveX']);
    expect(standings.first.totalPoints, standings.last.totalPoints);
  });

  test('refresh saves the standings; a failed one keeps what was saved', () async {
    SharedPreferences.setMockInitialValues({});
    AprlLeaderboardService.enabled = true;
    addTearDown(() => AprlLeaderboardService.enabled = false);

    final ok = MockClient((_) async => http.Response(jsonEncode(feed([result('Willy-SwerveX', 'R1 CB', 1, 36)])), 200));
    await AprlLeaderboardService.refresh(client: ok);
    expect((await ChampionshipStandingsStore.load()).single.totalPoints, 36);
    expect(await AprlLeaderboardService.lastFetched(), isNotNull);

    final down = MockClient((_) async => http.Response('oops', 500));
    await expectLater(AprlLeaderboardService.refresh(client: down), throwsException);
    expect((await ChampionshipStandingsStore.load()).single.totalPoints, 36);
  });

  group('the feed as tables (Nov 2026)', () {
    // Trimmed from the live feed on 18 Nov 2026.
    Map<String, dynamic> feed() => {
          'ok': true,
          'data': {
            'seriesList': ['Pro Series (GT3 Pro)', 'Development Series (GT3 Clubman)'],
            'series': [
              {
                'name': 'Pro Series (GT3 Pro)',
                'events': [
                  {'num': 1, 'track': 'Road Atlanta'},
                ],
                'rows': [
                  {'pos': 1, 'driver': 'Someone_Fast', 'scores': [40], 'dropIdx': null, 'total': 40},
                ],
              },
              {
                'name': 'Development Series (GT3 Clubman)',
                'events': [
                  {'num': 1, 'track': 'Michelin Raceway Road Atlanta'},
                  {'num': 2, 'track': 'Autodrome Lago Maggiore - West'},
                  {'num': 3, 'track': 'Mount Panorama Motor Racing Circuit'},
                  {'num': 4, 'track': 'Alsace - Village Reverse'},
                  {'num': 5, 'track': 'Nürburgring Sprint'},
                ],
                'rows': [
                  {'pos': 1, 'driver': 'Chuck_E82', 'scores': [26, 31, 35, 33, 33], 'dropIdx': 0, 'total': 132},
                  {'pos': 2, 'driver': 'Willy-SwerveX', 'scores': [33, 17, 33, 36, 18], 'dropIdx': 1, 'total': 120},
                  {'pos': 3, 'driver': 'sideshow-308', 'scores': [27, 33, 31, 27, 28], 'dropIdx': 0, 'total': 119},
                ],
              },
            ],
          },
        };

    test('our series is found by our name, not the page\'s default (Pro)', () {
      final standings = AprlLeaderboardService.standingsFrom(feed());
      expect([for (final s in standings) s.driverName], ['Chuck_E82', 'Willy-SwerveX', 'sideshow-308']);
      expect([for (final s in standings) s.totalPoints], [132, 120, 119], reason: "the feed's totals");
      expect(standings[1].roundPoints, [33, 17, 33, 36, 18, null, null, null, null]);
      expect(standings[1].dropPoints, 17);
    });

    test('a series can still be asked for by name', () {
      final standings = AprlLeaderboardService.standingsFrom(feed(), series: 'Pro Series (GT3 Pro)');
      expect(standings.single.driverName, 'Someone_Fast');
      expect(standings.single.totalPoints, 40);
    });
  });
}
