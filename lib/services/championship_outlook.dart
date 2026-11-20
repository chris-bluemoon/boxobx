import 'dart:math' as math;

import '../models/championship_standing.dart';

/// What the next round has to bring against one rival: for a few
/// finishing places of ours (around where we usually finish), the place
/// they'd have to finish for us to pass them (a rival ahead) or for them
/// to pass us (a rival behind).
class RivalScenario {
  final String driver;

  /// Points between us now (+ = they're ahead).
  final int gapNow;
  final bool ahead;

  /// (our place, their place): ahead -- we pass them if they finish that
  /// place or lower (41 = only if they don't score); behind -- they pass us if they finish that place or
  /// higher. Places where it can't happen are left out.
  final List<(int, int)> cases;

  /// Ahead: we pass them just by finishing in front (any places).
  /// Behind: they pass us just by finishing in front.
  final bool finishingAheadIsEnough;

  /// Ahead: we can't pass them next round whatever happens.
  final bool outOfReach;

  const RivalScenario({
    required this.driver,
    required this.gapNow,
    required this.ahead,
    this.cases = const [],
    this.finishingAheadIsEnough = false,
    this.outOfReach = false,
  });

  String describe() {
    final gap = gapNow.abs();
    final pts = '$gap pt${gap == 1 ? '' : 's'}';
    if (ahead) {
      final head = 'To pass $driver ($pts ahead)';
      if (outOfReach) return "$head: not possible next round.";
      if (finishingAheadIsEnough) return '$head: finish ahead of them.';
      if (cases.isEmpty) return '$head: needs a better result than you usually get.';
      return '$head: ${cases.map((c) => '${_place(c.$1)} with them ${c.$2 > 40 ? 'not scoring' : 'P${c.$2} or lower'}').join(' · ')}.';
    }
    final head = gapNow == 0 ? '$driver (level on points)' : '$driver ($pts behind)';
    if (finishingAheadIsEnough) return '$head passes you if they finish ahead of you.';
    if (cases.isEmpty) return "$head can't pass you next round.";
    return '$head passes you if: ${cases.map((c) => 'you ${_place(c.$1)}, they P${c.$2} or higher').join(' · ')}.';
  }

  static String _place(int p) => p == 1 ? 'win' : 'P$p';
}

/// Championship maths for the APRL tab: where we stand, what the next
/// round needs against the drivers around us, and whether the title is
/// still on. Uses the league's rules -- points by place
/// ([pointsTable], then one fewer a place), a fastest-lap bonus (left
/// out here: nobody can plan on it), and each driver's lowest round
/// dropped. Ties go to countback, so level counts as not passed.
class ChampionshipOutlook {
  /// APRL points for P1, P2, ... (from the leaderboard site); below the
  /// table, one fewer a place, down to 1.
  static const List<int> pointsTable = [35, 33, 31, 29, 28, 27, 26, 25, 24, 23, 22, 21, 20, 19, 18];

  /// A win with fastest lap -- the most a round can bring.
  static const int maxRoundPoints = 36;

  static int pointsFor(int place) {
    if (place <= 0) return 0;
    if (place <= pointsTable.length) return pointsTable[place - 1];
    return math.max(1, pointsTable.last - (place - pointsTable.length));
  }

  final int roundsDone;
  final int totalRounds;
  final int ourPosition;
  final int ourPoints;

  /// The place we usually finish (from our typical round score).
  final int typicalPlace;

  final List<RivalScenario> rivals;

  /// The title: still mathematically on (and how far off the lead).
  final bool titlePossible;
  final int pointsToLeader;

  const ChampionshipOutlook({
    required this.roundsDone,
    required this.totalRounds,
    required this.ourPosition,
    required this.ourPoints,
    required this.typicalPlace,
    required this.rivals,
    required this.titlePossible,
    required this.pointsToLeader,
  });

  int get roundsLeft => math.max(0, totalRounds - roundsDone);
  int get nextRound => roundsDone + 1;

  /// [standings] in championship order; null if we're not in them or the
  /// season's over.
  static ChampionshipOutlook? of(
    List<ChampionshipStanding> standings, {
    required String player,
    int totalRounds = 9,
    int rivalsEachSide = 2,
  }) {
    final us = standings.indexWhere((s) => s.driverName == player);
    if (us < 0) return null;
    final done = standings.fold<int>(0, (n, s) {
      final last = s.roundPoints.lastIndexWhere((p) => p != null);
      return math.max(n, last + 1);
    });
    if (done >= totalRounds) return null;

    List<int> scoresOf(ChampionshipStanding s) => [for (var i = 0; i < done; i++) s.roundPoints[i] ?? 0];
    final me = standings[us];
    final mine = scoresOf(me);

    // Where we usually finish: the place our median round score is worth.
    final sorted = [...mine]..sort();
    final median = sorted.isEmpty ? pointsFor(10) : sorted[sorted.length ~/ 2];
    var typical = 1;
    while (pointsFor(typical) > median && typical < 40) {
      typical++;
    }
    final ourPlaces = {
      for (final p in [typical - 1, typical, typical + 1]) math.max(1, p),
    }.toList()..sort();

    int after(List<int> scores, int place) => _total([...scores, pointsFor(place)]);

    final rivals = <RivalScenario>[];
    for (var i = math.max(0, us - rivalsEachSide); i < math.min(standings.length, us + rivalsEachSide + 1); i++) {
      if (i == us) continue;
      final rival = standings[i];
      final theirs = scoresOf(rival);
      final ahead = i < us;
      final gap = rival.totalPoints - me.totalPoints;
      if (ahead) {
        // For each place of ours, the highest place they can finish and
        // still end up behind us (0 = only if they don't score).
        final cases = <(int, int)>[];
        var aheadEnough = true;
        for (var a = 1; a <= 20; a++) {
          int? b;
          for (var p = 1; p <= 41; p++) {
            if (p == a) continue;
            final their = p == 41 ? _total([...theirs, 0]) : after(theirs, p);
            if (after(mine, a) > their) {
              b = p;
              break;
            }
          }
          if (b == null || b > a + 1) aheadEnough = false;
          if (ourPlaces.contains(a) && b != null) cases.add((a, b));
        }
        final reachable = after(mine, 1) > _total([...theirs, 0]);
        rivals.add(
          RivalScenario(
            driver: rival.driverName,
            gapNow: gap,
            ahead: true,
            cases: cases,
            finishingAheadIsEnough: aheadEnough,
            outOfReach: !reachable,
          ),
        );
      } else {
        // For each place of ours, the lowest place they can finish and
        // still pass us.
        final cases = <(int, int)>[];
        var aheadEnough = true;
        for (var a = 1; a <= 20; a++) {
          int? b;
          for (var p = 40; p >= 1; p--) {
            if (p == a) continue;
            if (after(theirs, p) > after(mine, a)) {
              b = p;
              break;
            }
          }
          if (a > 1 && b != a - 1) aheadEnough = false;
          if (ourPlaces.contains(a) && b != null) cases.add((a, b));
        }
        rivals.add(
          RivalScenario(
            driver: rival.driverName,
            gapNow: gap,
            ahead: false,
            cases: cases,
            finishingAheadIsEnough: aheadEnough,
          ),
        );
      }
    }

    // The title: our best (a win with fastest lap every round left)
    // against the leader's worst (no points at all).
    final leader = standings.first;
    final left = totalRounds - done;
    final best = _total([...mine, for (var r = 0; r < left; r++) maxRoundPoints]);
    final leaderWorst = _total([...scoresOf(leader), for (var r = 0; r < left; r++) 0]);
    return ChampionshipOutlook(
      roundsDone: done,
      totalRounds: totalRounds,
      ourPosition: us + 1,
      ourPoints: me.totalPoints,
      typicalPlace: typical,
      rivals: rivals,
      titlePossible: us == 0 || best > leaderWorst,
      pointsToLeader: leader.totalPoints - me.totalPoints,
    );
  }

  /// The season total as the league works it: every round, less the lowest.
  static int _total(List<int> scores) {
    if (scores.isEmpty) return 0;
    final sum = scores.reduce((a, b) => a + b);
    return scores.length >= 2 ? sum - scores.reduce(math.min) : sum;
  }

  /// The title line, e.g. "Title: P2, 12 pts off the lead with 4 rounds left -- still on."
  String titleLine() {
    final rounds = '$roundsLeft round${roundsLeft == 1 ? '' : 's'} left';
    if (ourPosition == 1) return 'Title: you lead with $rounds.';
    return 'Title: P$ourPosition, $pointsToLeader pt${pointsToLeader == 1 ? '' : 's'} off the lead with $rounds'
        ' -- ${titlePossible ? 'still on' : 'out of reach'}.';
  }
}
