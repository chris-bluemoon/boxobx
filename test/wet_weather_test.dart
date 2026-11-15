import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/opponent_pit_stop.dart';
import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/models/weather_forecast.dart';
import 'package:boxbox/services/practice_lap_logger.dart';
import 'package:boxbox/services/stint_summary.dart';
import 'package:boxbox/services/wet_pace_table.dart';
import 'package:boxbox/services/wet_tyre_caller.dart';

var _seq = 0;

/// A practice stint of [n] laps at about [lapMs].
List<PracticeLapRecord> _stint(int stint, String tyre, String? weather, int lapMs, {int n = 5, bool race = false}) => [
  for (var i = 0; i < n; i++)
    PracticeLapRecord(
      lapNumber: ++_seq,
      lapTimeMs: lapMs + const [0, 60, -60, 40, -40][i % 5],
      tireCompound: tyre,
      fuelPercentAtLapStart: 100 - i * 3.0,
      fuelPercentAtLapEnd: 97 - i * 3.0,
      recordedAt: DateTime(2026, 11, 15, 10, _seq),
      stintNumber: stint,
      weather: weather,
      isRaceLap: race,
      raceNumber: race ? 1 : null,
    ),
];

void main() {
  final brief = WeatherForecast.tryParse('R06/R05/C03/S14/S04/R03/R04/R05')!;

  group('wet testing', () {
    test('each lap carries the weather set on the dashboard; a change is a new stint', () {
      final logger = PracticeLapLogger();
      void lap(int n) => logger.update(_frameAt(n));
      lap(1);
      lap(2);
      logger.setWeather('R05');
      lap(3);
      lap(4);
      logger.setWeather('R05'); // same weather: same stint
      lap(5);
      expect(logger.laps.map((l) => l.weather), [null, 'R05', 'R05', 'R05']);
      expect(logger.laps.map((l) => l.stintNumber), [1, 2, 2, 2]);
      final stint = StintSummary.fromLaps(logger.laps).first;
      expect(stint.weatherLevel, 'R05');
      expect(stint.label('Round 5'), endsWith(', Weather R05'));
      // After a restart it's back to dry, not the weather last tested.
      expect((PracticeLapLogger()..seedWithPersistedLaps(logger.laps)).currentWeather, isNull);
    });

    test('deleting a stint removes all its laps and renumbers the rest', () {
      final logger = PracticeLapLogger();
      void lap(int n) => logger.update(_frameAt(n));
      lap(1);
      lap(2);
      lap(3);
      logger.setWeather('R05');
      lap(4);
      lap(5);
      final stintOne = {for (final l in logger.laps.where((l) => l.stintNumber == 1)) l.recordedAt};
      expect(stintOne, hasLength(2));
      logger.removeLaps(stintOne);
      expect(logger.laps.map((l) => l.stintNumber), [2, 2]);
      expect(logger.laps.map((l) => l.lapNumber), [1, 2]);
    });

    test('the grid: pace per tyre per weather, latest stint, quickest slick', () {
      final table = WetPaceTable.fromLaps([
        ..._stint(1, 'Intermediate', 'R06', 104000),
        ..._stint(2, 'Heavy Wet', 'R06', 102000),
        ..._stint(3, 'Intermediate', 'R06', 103500), // latest inters run counts
        ..._stint(4, 'Racing Medium', null, 92000),
        ..._stint(5, 'Racing Soft', null, 91500),
        ..._stint(6, 'Intermediate', null, 95000),
        ..._stint(7, 'Heavy Wet', 'R05', 99000, n: 2), // too short to count
        ..._stint(8, 'Intermediate', 'R05', 90000, race: true), // race laps aren't testing
      ]);
      expect(table.pace('R06', WeatherTyre.inters)!.lapMs, 103500);
      expect(table.pace('DRY', WeatherTyre.slicks)!.compound, 'Racing Soft');
      expect(table.pace('R05', WeatherTyre.wets), isNull);
      expect(table.pace('R05', WeatherTyre.inters), isNull);

      final wet = table.compare('R06')!;
      expect((wet.faster, wet.deltaMs), (WeatherTyre.wets, 1500));
      expect(wet.lapsToPayBack(30), 20);
      expect(table.compare('DRY')!.faster, WeatherTyre.slicks);

      expect(table.levelsFor(brief), ['DRY', 'R03', 'R04', 'R05', 'R06']);
      expect(table.toTest(brief), [
        ('R05', WeatherTyre.inters), ('R05', WeatherTyre.wets),
        ('R04', WeatherTyre.inters), ('R04', WeatherTyre.wets),
        ('R03', WeatherTyre.slicks), ('R03', WeatherTyre.inters),
      ]);
      expect(table.toPromptContext(pitLossSeconds: 30).first, startsWith('DRY: Racing (slicks) 1:31.500 Intermediate 1:35.000 -> Racing (slicks) 3.5s/lap faster, pays back a 30s stop in 9 laps'));
    });
  });

  group('tyre calls in the race', () {
    // 26 laps: Wets 1-3, Inters 4-7, slicks 8-16, Inters 17-26.
    WetTyreDecision? decide(int lap, String tyre, WetPaceTable pace, {List<int> stops = const [], List<OpponentPitStop> rivals = const []}) =>
        WetTyreCaller.decide(
          forecast: brief,
          currentLap: lap,
          totalLaps: 26,
          currentCompound: tyre,
          pace: pace,
          pitLossSeconds: 30,
          plannedStopLaps: stops,
          opponentStops: rivals,
        );
    final dryTested = WetPaceTable.fromLaps([
      ..._stint(1, 'Racing Medium', null, 92000),
      ..._stint(2, 'Intermediate', null, 97000),
    ]);

    test('no call in the opening spell: starting on Inters under R06 is the plan', () {
      for (var lap = 1; lap <= 3; lap++) {
        expect(decide(lap, 'Intermediate', dryTested), isNull);
      }
      expect(decide(5, 'Intermediate', dryTested), isNull, reason: 'R05 calls for inters');
    });

    test('drying: waits for the track, then boxes when slicks pay back the stop', () {
      expect(decide(8, 'Intermediate', dryTested), isNull);
      expect(decide(9, 'Intermediate', dryTested), isNull);
      final d = decide(10, 'Intermediate', dryTested)!;
      expect(d.target, WeatherTyre.slicks);
      expect(d.lapsOnTarget, 7); // laps 10-16
      expect(d.verdict, WetVerdict.box); // 5s x 7 = 35s > 30s
      expect(decide(12, 'Intermediate', dryTested)!.verdict, WetVerdict.stayOut, reason: '5 laps x 5s < 30s');
    });

    test('a planned fuel stop in the window makes the change free; untested says the break-even', () {
      expect(decide(13, 'Intermediate', dryTested, stops: [14])!.verdict, WetVerdict.boxAtPlannedStop);
      final untested = decide(10, 'Intermediate', WetPaceTable.fromLaps(const []))!;
      expect(untested.verdict, WetVerdict.untested);
      expect(untested.breakEvenPerLapSeconds, closeTo(4.3, 0.05));
    });

    test('rivals who already fitted the tyre are named', () {
      final d = decide(10, 'Intermediate', dryTested, rivals: [
        OpponentPitStop(driver: 'Chuck_E82', ourLap: 9, tyre: 'M', seenAt: DateTime(2026)),
        OpponentPitStop(driver: 'Early', ourLap: 3, tyre: 'M', seenAt: DateTime(2026)),
      ])!;
      expect(d.rivalsOnTarget.map((s) => s.driver), ['Chuck_E82']);
    });

    test('Boxington: one switch call per spell, and a warning before rain', () {
      final caller = WetTyreCaller();
      final laps = [..._stint(1, 'Racing Medium', null, 92000), ..._stint(2, 'Intermediate', null, 97000)];
      String? check(int lap, String tyre) => caller.check(
        forecast: brief,
        currentLap: lap,
        totalLaps: 26,
        currentCompound: tyre,
        laps: laps,
        pitLossSeconds: 30,
      );
      expect(check(9, 'Intermediate'), isNull);
      final call = check(10, 'Intermediate')!;
      expect(call, contains('Call the driver in for Racing (slicks)'));
      expect(check(11, 'Intermediate'), isNull, reason: 'called once for the spell');
      // On slicks, rain (R03) is due from lap 17.
      expect(check(14, 'Racing Medium'), isNull);
      expect(check(15, 'Racing Medium'), contains('R03 Light Rain due from about lap 17'));
      expect(check(16, 'Racing Medium'), isNull);
    });
  });

  _liveTrackTests();
}

/// A frame on lap [lap] of a session (the lap before it took 90 s).
TelemetryFrame _frameAt(int lap) => TelemetryFrame(
  rpm: 6000,
  speedKmh: 150,
  gear: 4,
  posX: 0,
  posY: 0,
  posZ: 0,
  lapDistance: 0,
  trackLength: 0,
  fuelPercent: 100 - lap * 3.0,
  tireTemps: const [80, 80, 80, 80],
  currentLap: lap,
  lastLapTimeMs: lap == 1 ? -1 : 90000,
);

void _liveTrackTests() {
  group('Boxington reads the track from the lap times', () {
    final dryBrief = WeatherForecast.tryParse('S04/S04/S04/S04')!;
    String? check(WetTyreCaller caller, WeatherForecast brief, List<PracticeLapRecord> laps, String tyre, {int lap = 8}) =>
        caller.check(
          forecast: brief,
          currentLap: lap,
          totalLaps: 20,
          currentCompound: tyre,
          laps: laps,
          pitLossSeconds: 30,
        );

    test('rain the brief missed: slick laps that match R03 testing call for inters', () {
      final laps = [
        ..._stint(1, 'Racing Medium', 'R03', 100000),
        ..._stint(2, 'Intermediate', 'R03', 95000),
        ..._stint(3, 'Racing Medium', null, 90000),
        ..._stint(4, 'Racing Medium', null, 100000, n: 3, race: true),
      ];
      final caller = WetTyreCaller();
      final call = check(caller, dryBrief, laps, 'Racing Medium')!;
      expect(call, contains('from the lap times'));
      expect(call, contains('match R03'));
      expect(call, contains('Call the driver in for Intermediate'));
      expect(check(caller, dryBrief, laps, 'Racing Medium', lap: 9), isNull, reason: 'once');
    });

    test('untested: Pirelli\'s 110% of dry pace rule', () {
      final laps = [
        ..._stint(1, 'Racing Medium', null, 90000),
        ..._stint(2, 'Racing Medium', null, 100000, n: 3, race: true), // 111%
      ];
      final call = check(WetTyreCaller(), dryBrief, laps, 'Racing Medium')!;
      expect(call, contains('111% of dry pace'));
      expect(call, contains('110%'));

      final slower = [
        ..._stint(1, 'Racing Medium', null, 90000),
        ..._stint(2, 'Racing Medium', null, 97000, n: 3, race: true), // 108%
      ];
      expect(check(WetTyreCaller(), dryBrief, slower, 'Racing Medium'), isNull);
    });

    test('the window runs on when the rain came early', () {
      // Slicks now, R04 from about lap 11: inters from lap 8 run to the end.
      final brief = WeatherForecast.tryParse('S04/S04/R04/R04')!;
      final d = WetTyreCaller.readTrack(
        forecast: brief,
        currentLap: 8,
        totalLaps: 20,
        currentCompound: 'Racing Medium',
        laps: [
          ..._stint(1, 'Racing Medium', 'R03', 100000),
          ..._stint(2, 'Intermediate', 'R03', 95000),
          ..._stint(4, 'Racing Medium', null, 100000, n: 3, race: true),
        ],
        pace: WetPaceTable.fromLaps([..._stint(1, 'Racing Medium', 'R03', 100000), ..._stint(2, 'Intermediate', 'R03', 95000)]),
        pitLossSeconds: 30,
      )!;
      expect(d.lapsOnTarget, 13);
    });

    test('inters at R06 that match testing: wets not worth it, nothing said', () {
      final laps = [
        ..._stint(1, 'Intermediate', 'R06', 104200),
        ..._stint(2, 'Heavy Wet', 'R06', 102900),
        ..._stint(3, 'Intermediate', null, 104200, n: 3, race: true),
      ];
      final brief = WeatherForecast.tryParse('R06/R05/C03/S14/S04/R03/R04/R05')!;
      expect(check(WetTyreCaller(), brief, laps, 'Intermediate', lap: 3), isNull);
    });
  });
}
