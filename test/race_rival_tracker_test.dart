import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/hud_overlay_data.dart';
import 'package:boxbox/models/opponent_pit_stop.dart';
import 'package:boxbox/models/traffic_map.dart';
import 'package:boxbox/services/race_rival_tracker.dart';

const _lap = 90.0;
const _rate = 1000 / _lap; // lap-progress units per second at our pace

/// A race seen through the relay 5 times a second: us, the rival and
/// other cars moving round a 90 s lap on the course map, plus the
/// leaderboard rows when the rival is near us on it.
class _Race {
  final tracker = RaceRivalTracker()..setRival('Chuck_E82');
  var now = DateTime(2026, 11, 14, 20);
  double me = 100;
  double rival;
  double rivalRate = _rate;
  List<double> others;
  int ourLap = 1;
  int ourLastLapMs = -1;
  double? pitLapProgress;
  final events = <RivalEvent>[];

  _Race({required this.rival, this.others = const []});

  TrafficMap get map => TrafficMap(
        trackReady: true,
        playerLapProgress: me,
        lapSeconds: _lap,
        cars: [
          for (final p in [rival, ...others]) TrafficCar(lapProgress: p, secondsBehind: ((me - p) % 1000) / _rate),
        ],
      );

  /// Steps [seconds]; [board] gives the leaderboard rows each step.
  void run(double seconds, {List<StandingsRow> Function()? board}) {
    for (var i = 0; i < (seconds * 5).round(); i++) {
      now = now.add(const Duration(milliseconds: 200));
      final before = me;
      me = (me + _rate * 0.2) % 1000;
      rival = (rival + rivalRate * 0.2) % 1000;
      others = [for (final p in others) (p + _rate * 0.2) % 1000];
      if (me < before) {
        ourLap++;
        ourLastLapMs = 90000;
      }
      events.addAll(tracker.update(
        HudOverlayData(gridPosition: 5, standings: board?.call() ?? const [], traffic: map),
        ourLap: ourLap,
        ourLastLapMs: ourLastLapMs,
        pitLapProgress: pitLapProgress,
        now: now,
      ));
    }
  }

  List<String> get prompts => [for (final e in events) e.prompt];
}

/// Rival at [rivalPosition] directly ahead of us (P5) by [gap] seconds.
List<StandingsRow> _rivalAhead({int rivalPosition = 4, double gap = 1.5, bool inPit = false}) => [
      StandingsRow(name: 'Chuck_E82', position: rivalPosition, inPit: inPit),
      StandingsRow(name: 'Willy-SwerveX', position: 5, gapToAhead: gap, isPlayer: true),
    ];

void main() {
  group('leaderboard', () {
    test('a confirmed position change is called, with whether they got past us', () {
      final race = _Race(rival: 120);
      race.run(1, board: () => _rivalAhead(rivalPosition: 4));
      race.run(1, board: () => [
            const StandingsRow(name: 'Willy-SwerveX', position: 5, isPlayer: true),
            const StandingsRow(name: 'Chuck_E82', position: 6, gapToAhead: 0.4),
          ]);
      expect(race.prompts, hasLength(1));
      expect(race.prompts.single, contains('dropped back to P6 (was P4)'));
      expect(race.prompts.single, contains('We are now ahead of them'));
      expect(race.tracker.state!.position, 6);
    });

    test('a single misread position is not a change', () {
      final race = _Race(rival: 120);
      race.run(1, board: () => _rivalAhead(rivalPosition: 4));
      race.run(0.2, board: () => _rivalAhead(rivalPosition: 9));
      race.run(1, board: () => _rivalAhead(rivalPosition: 4));
      expect(race.events, isEmpty);
    });

    test('the gap is summed over every interval between us', () {
      final race = _Race(rival: 140);
      race.run(0.4, board: () => const [
            StandingsRow(name: 'Chuck_E82', position: 3),
            StandingsRow(name: 'SushiSuzie', position: 4, gapToAhead: 1.2),
            StandingsRow(name: 'Willy-SwerveX', position: 5, gapToAhead: 0.9, isPlayer: true),
          ]);
      expect(race.tracker.state!.gapSeconds, closeTo(-2.1, 1e-9));
      expect(race.tracker.state!.gapSource, 'leaderboard');
    });

    test('no gap from the leaderboard when positions between us are missing from it', () {
      final race = _Race(rival: 140);
      race.run(0.4, board: () => const [
            StandingsRow(name: 'Chuck_E82', position: 2),
            StandingsRow(name: 'Willy-SwerveX', position: 5, gapToAhead: 0.9, isPlayer: true),
          ]);
      expect(race.tracker.state!.gapSource, isNot('leaderboard'));
    });
  });

  group('course map', () {
    test('locks on from the leaderboard gap, then follows them off the board', () {
      // Rival 1.5 s ahead (13.9 units); other cars well away.
      final race = _Race(rival: 100 + 1.5 * _rate, others: [400, 700]);
      race.run(1, board: () => _rivalAhead(gap: 1.5));
      expect(race.tracker.state!.onMap, isTrue);

      // The rival pulls away and leaves the leaderboard window.
      race.rivalRate = _rate * 1.05;
      race.run(40);
      final state = race.tracker.state!;
      expect(state.onMap, isTrue);
      expect(state.gapSource, 'courseMap');
      expect(state.gapSeconds!, closeTo(-(1.5 + 40 * 0.05), 0.6));
    });

    test('does not lock on when two cars are at much the same gap', () {
      final race = _Race(rival: 100 + 1.5 * _rate, others: [100 + 1.8 * _rate]);
      race.run(1, board: () => _rivalAhead(gap: 1.5));
      expect(race.tracker.state!.onMap, isFalse);
    });

    test('times their laps from the map', () {
      final race = _Race(rival: 100 + 2 * _rate, others: [500]);
      race.run(1, board: () => _rivalAhead(gap: 2));
      race.rivalRate = 1000 / 88; // an 88 s lap
      race.run(200);
      expect(race.tracker.state!.lapSeconds, isNotEmpty);
      for (final lap in race.tracker.state!.lapSeconds) {
        expect(lap, closeTo(88, 0.6));
      }
    });

    test('a spin on track is called straight away', () {
      final race = _Race(rival: 100 + 3 * _rate, others: [600]);
      race.run(1, board: () => _rivalAhead(gap: 3));
      race.run(10);
      race.rivalRate = 0;
      race.run(4);
      expect(race.prompts.where((p) => p.contains('spin or an off')), hasLength(1));
      expect(race.tracker.state!.inTrouble, isTrue);
      expect(race.prompts.last, contains('up the road'));

      // Back up to speed: no longer in trouble, and no repeat call.
      race.rivalRate = _rate;
      race.run(8);
      expect(race.tracker.state!.inTrouble, isFalse);
      expect(race.prompts.where((p) => p.contains('spin or an off')), hasLength(1));
    });

    test('slowing by the pits is called as a probable stop, not a spin', () {
      final race = _Race(rival: 100 + 3 * _rate, others: [600]);
      race.run(1, board: () => _rivalAhead(gap: 3));
      race.run(5);
      race.pitLapProgress = race.rival + 5;
      race.rivalRate = 0;
      race.run(4);
      expect(race.prompts.single, contains('pitting'));
    });

    test('no trouble call when their row shows the pit marker', () {
      final race = _Race(rival: 100 + 3 * _rate, others: [600]);
      race.run(1, board: () => _rivalAhead(gap: 3));
      race.rivalRate = 0;
      race.run(4, board: () => _rivalAhead(gap: 3, inPit: true));
      expect(race.events, isEmpty);
      expect(race.tracker.state!.inPit, isTrue);
    });
  });

  test('a pace and gap update every 3 of our laps', () {
    final race = _Race(rival: 100 + 2 * _rate, others: [500]);
    race.run(1, board: () => _rivalAhead(gap: 2));
    race.rivalRate = 1000 / 89;
    race.run(3 * _lap + 2);
    final updates = race.prompts.where((p) => p.startsWith('RACE RIVAL UPDATE')).toList();
    expect(updates, hasLength(1));
    expect(updates.single, contains('ahead of us'));
    race.run(3 * _lap);
    final second = race.prompts.where((p) => p.startsWith('RACE RIVAL UPDATE')).last;
    expect(second, contains('we have lost'));
  });

  test('nothing without a rival chosen, and choosing one starts afresh', () {
    final race = _Race(rival: 120);
    race.tracker.setRival(null);
    race.run(2, board: () => _rivalAhead());
    expect(race.tracker.state, isNull);
    expect(race.events, isEmpty);

    race.tracker.setRival('Chuck_E82');
    race.run(0.4, board: () => _rivalAhead());
    expect(race.tracker.state!.name, 'Chuck_E82');
  });

  test("the prompt context includes the rival's pit stops", () {
    final race = _Race(rival: 120);
    race.run(0.4, board: () => _rivalAhead());
    final context = race.tracker.state!.toPromptContext([
      OpponentPitStop(driver: 'Chuck_E82', position: 4, ourLap: 9, tyre: 'M', seenAt: race.now),
      OpponentPitStop(driver: 'SushiSuzie', position: 2, ourLap: 9, seenAt: race.now),
    ]);
    expect(context['name'], 'Chuck_E82');
    expect(context['pitStops'], hasLength(1));
  });
}
