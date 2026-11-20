// Covers ChampionshipOutlook: what the next APRL round needs against the
// drivers around us, with the lowest round dropped.
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/championship_standing.dart';
import 'package:boxbox/services/championship_outlook.dart';

ChampionshipStanding _s(String name, List<int> scores) {
  final points = List<int?>.filled(9, null);
  for (var i = 0; i < scores.length; i++) {
    points[i] = scores[i];
  }
  final drop = scores.length >= 2 ? scores.reduce((a, b) => a < b ? a : b) : 0;
  return ChampionshipStanding(driverName: name, roundPoints: points, dropPoints: drop);
}

// The Clubman table after Round 5.
final _standings = [
  _s('Chuck_E82', [26, 31, 35, 33, 33]), // 132
  _s('Willy-SwerveX', [33, 17, 33, 36, 18]), // 120
  _s('sideshow-308', [27, 33, 31, 27, 28]), // 119
  _s('warrenb313-wazza', [31, 28, 0, 24, 35]), // 118
];

void main() {
  test('the points table: 35, 33, 31, 29, 28 ... 18 for P15, then one fewer a place', () {
    expect(ChampionshipOutlook.pointsFor(1), 35);
    expect(ChampionshipOutlook.pointsFor(4), 29);
    expect(ChampionshipOutlook.pointsFor(15), 18);
    expect(ChampionshipOutlook.pointsFor(16), 17);
    expect(ChampionshipOutlook.pointsFor(0), 0);
  });

  test('a leader who drops a zero is out of reach for one round', () {
    final o = ChampionshipOutlook.of(_standings, player: 'Willy-SwerveX')!;
    expect(o.nextRound, 6);
    expect(o.roundsLeft, 4);
    expect(o.ourPosition, 2);
    expect(o.typicalPlace, 2); // median 33
    final chuck = o.rivals.firstWhere((r) => r.driver == 'Chuck_E82');
    // A win: 172 - 17 = 155. Chuck not scoring drops the 0: 158.
    expect(chuck.outOfReach, isTrue);
    expect(chuck.describe(), 'To pass Chuck_E82 (12 pts ahead): not possible next round.');
    expect(o.titlePossible, isTrue);
    expect(o.titleLine(), 'Title: P2, 12 pts off the lead with 4 rounds left -- still on.');
  });

  test('the driver behind: where they have to finish to pass us', () {
    final o = ChampionshipOutlook.of(_standings, player: 'Willy-SwerveX')!;
    final side = o.rivals.firstWhere((r) => r.driver == 'sideshow-308');
    expect(side.ahead, isFalse);
    // Us P2 (153): they need P1 (154). Us P3 (151): P2 (152).
    expect(side.cases, [(2, 1), (3, 2)]);
  });

  test('a rival ahead within reach: the place they must finish behind', () {
    final o = ChampionshipOutlook.of(_standings, player: 'sideshow-308')!;
    final willy = o.rivals.firstWhere((r) => r.driver == 'Willy-SwerveX');
    expect(willy.ahead, isTrue);
    expect(willy.outOfReach, isFalse);
    // sideshow usually finishes P5 (28): 174 - 27 = 147. Willy beats that
    // on 27 (P6) -- 120 + 27 = 147 is level, which countback decides --
    // so Willy has to finish P7 (26) or lower.
    expect(o.typicalPlace, 5);
    expect(willy.cases, contains((5, 7)));
  });

  test('not in the standings, or the season over: nothing', () {
    expect(ChampionshipOutlook.of(_standings, player: 'nobody'), isNull);
    expect(ChampionshipOutlook.of(_standings, player: 'Willy-SwerveX', totalRounds: 5), isNull);
  });
}
