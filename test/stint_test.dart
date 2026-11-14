import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/screens/practice_log_screen.dart';
import 'package:boxbox/services/practice_lap_logger.dart';
import 'package:boxbox/services/stint_summary.dart';

TelemetryFrame _frame(int lap, double fuel, {int lastLapTimeMs = 90000}) => TelemetryFrame(
  rpm: 0,
  speedKmh: 200,
  gear: 4,
  posX: 0,
  posY: 0,
  posZ: 0,
  lapDistance: 0,
  trackLength: 0,
  fuelPercent: fuel,
  tireTemps: const [0, 0, 0, 0],
  currentLap: lap,
  lastLapTimeMs: lap == 1 ? -1 : lastLapTimeMs,
);

PracticeLapRecord _lap({
  required int stint,
  required double fuelStart,
  double fuelUsed = 3,
  int lapTimeMs = 90000,
  double? wear,
  String tyre = 'Racing Soft',
  bool pit = false,
  bool race = false,
}) => PracticeLapRecord(
  lapNumber: 1,
  lapTimeMs: lapTimeMs,
  tireCompound: tyre,
  fuelPercentAtLapStart: fuelStart,
  fuelPercentAtLapEnd: fuelStart - fuelUsed,
  tireWearPercent: wear,
  recordedAt: DateTime(2026),
  isPitLap: pit,
  stintNumber: stint,
  isRaceLap: race,
);

void main() {
  group('stint numbering in PracticeLapLogger', () {
    test('the first laps are stint 1; a new stint starts only with the next recorded lap', () {
      final logger = PracticeLapLogger();
      logger.update(_frame(1, 100));
      logger.update(_frame(2, 97));
      logger.update(_frame(3, 94));
      expect(logger.laps.map((l) => l.stintNumber), [1, 1]);

      logger.startNewStint();
      logger.startNewStint(); // repeated requests don't skip numbers
      logger.update(_frame(4, 91));
      expect(logger.laps.last.stintNumber, 2);
      expect(logger.currentStint, 2);
    });

    test('going out on track again starts a new stint', () {
      final logger = PracticeLapLogger();
      logger.update(_frame(1, 100));
      logger.update(_frame(2, 97));
      logger.startNewSession();
      logger.update(_frame(1, 100));
      logger.update(_frame(2, 97));
      expect(logger.laps.map((l) => l.stintNumber), [1, 2]);
    });

    test('after a restart, new laps continue from the highest saved stint', () {
      final logger = PracticeLapLogger()..seedWithPersistedLaps([_lap(stint: 3, fuelStart: 50)]);
      logger.update(_frame(1, 100));
      logger.update(_frame(2, 97));
      expect(logger.laps.last.stintNumber, 4);
    });

    test('clearing the log starts again at stint 1, and race mode tags laps', () {
      final logger = PracticeLapLogger()..seedWithPersistedLaps([_lap(stint: 3, fuelStart: 50)]);
      logger.reset();
      logger.isRaceMode = true;
      logger.update(_frame(1, 100));
      logger.update(_frame(2, 97));
      expect(logger.laps.single.stintNumber, 1);
      expect(logger.laps.single.isRaceLap, isTrue);
    });
  });

  group('StintSummary', () {
    final stint1 = [
      _lap(stint: 1, fuelStart: 100, lapTimeMs: 90000, wear: 97),
      _lap(stint: 1, fuelStart: 97, lapTimeMs: 90200, wear: 94),
      _lap(stint: 1, fuelStart: 94, lapTimeMs: 90400, wear: 91),
      _lap(stint: 1, fuelStart: 91, lapTimeMs: 90600, wear: 88),
    ];

    test('the label reads like the round, mode, stint, start fuel and tyre', () {
      final s = StintSummary.fromLaps(stint1).single;
      expect(s.label('Round 5'), 'Round 5 Testing - Stint 1 - Fuel 100%, Tyre RS');
      final race = StintSummary.fromLaps([_lap(stint: 2, fuelStart: 64, tyre: 'Racing Medium', race: true)]).single;
      expect(race.label('Round 5'), 'Round 5 Race - Stint 2 - Fuel 64%, Tyre RM');
    });

    test('fuel and tyre figures, and how long each would last', () {
      final s = StintSummary.fromLaps(stint1).single;
      expect(s.lapCount, 4);
      expect(s.fuelPerLapPercent, 3.0);
      expect(s.projectedFuelLaps, closeTo(33.3, 0.1)); // 100% / 3% per lap
      expect(s.tyreWearPerLapPercent, 3.0); // 97 -> 88 over 3 laps
      expect(s.projectedTyreLaps, closeTo(33.3, 0.1));
      expect(s.averageLapMs, 90300);
      expect(s.dropOffMs, 400); // last 2 avg 90500 - first 2 avg 90100
    });

    test('pit laps are left out of the figures', () {
      final s = StintSummary.fromLaps([
        ...stint1,
        _lap(stint: 1, fuelStart: 88, fuelUsed: -40, lapTimeMs: 120000, pit: true),
      ]).single;
      expect(s.lapCount, 4);
      expect(s.fuelPerLapPercent, 3.0);
      expect(s.averageLapMs, 90300);
    });

    test('stints are grouped newest first, with pre-stint laps as their own group', () {
      final groups = StintSummary.fromLaps([_lap(stint: 0, fuelStart: 80), ...stint1, _lap(stint: 2, fuelStart: 100)]);
      expect(groups.map((g) => g.stintNumber), [2, 1, 0]);
      expect(groups.last.label('Round 5'), 'Round 5 - Earlier laps (before stints)');
    });

    test('figures are null rather than guessed when there is not enough data', () {
      final s = StintSummary.fromLaps([_lap(stint: 1, fuelStart: 100)]).single;
      expect(s.tyreWearPerLapPercent, isNull);
      expect(s.projectedTyreLaps, isNull);
      expect(s.dropOffMs, isNull);
    });
  });

  group('representative laps and tyre drop-off', () {
    // Lap-to-lap scatter of a decent driver, about +-0.2 s.
    const noise = [0, 150, -120, 210, -80, 60, -190, 130, -40, 170, -150, 90, -60, 200, -110, 40, -170, 120];

    List<PracticeLapRecord> laps(List<int> times, {double wearStart = 100, double wearPerLap = 4}) => [
      for (final (i, t) in times.indexed)
        PracticeLapRecord(
          lapNumber: i + 1,
          lapTimeMs: t,
          tireCompound: 'Racing Soft',
          fuelPercentAtLapStart: 100 - i * 3.0,
          fuelPercentAtLapEnd: 97 - i * 3.0,
          tireWearPercent: wearStart - (i + 1) * wearPerLap,
          recordedAt: DateTime(2026, 1, 1, 0, i),
          stintNumber: 1,
        ),
    ];

    test('a spin and a cold out-lap are left out; ordinary scatter is not', () {
      final times = [for (var i = 0; i < 12; i++) 90000 + noise[i]];
      times[0] = 93500; // out-lap on cold tyres
      times[6] = 98000; // spin
      final s = StintSummary.fromLaps(laps(times)).single;
      expect(s.excludedLaps.map((l) => l.lapNumber), [1, 7]);
      expect(s.lapCount, 10);
      expect(s.consistencyMs!, inInclusiveRange(100, 250));
      expect(s.bestLapMs, 89850); // lap 11; lap 7 (the spin) is out
      expect(s.averageLapMs!, closeTo(90000, 120));
      expect(s.tyreDropOff, isNull);
    });

    test('steady pace with scatter and a spin is no drop-off', () {
      final times = [for (var i = 0; i < 18; i++) 90000 + noise[i]];
      times[9] = 96000;
      expect(StintSummary.fromLaps(laps(times)).single.tyreDropOff, isNull);
    });

    test('a cliff: pace holds, then falls away and stays down', () {
      final times = [
        for (var i = 0; i < 16; i++) 90000 + noise[i] + (i >= 10 ? 1200 + (i - 10) * 300 : 0),
      ];
      final s = StintSummary.fromLaps(laps(times)).single;
      final dropOff = s.tyreDropOff!;
      expect(dropOff.fromLapNumber, 11);
      expect(dropOff.lapsBeforeDropOff, 10);
      expect(dropOff.wearPercentAtDropOff, 60); // after lap 10 at 4%/lap
      expect(dropOff.lossMs, closeTo(2000, 300));
      expect(s.excludedLaps, isEmpty); // the slow laps are the tyres, not mistakes
    });

    test('gradual wear is a drop-off once it is clearly past the scatter', () {
      final times = [for (var i = 0; i < 14; i++) 90000 + noise[i] + i * 120];
      final dropOff = StintSummary.fromLaps(laps(times)).single.tyreDropOff!;
      expect(dropOff.fromLapNumber, inInclusiveRange(6, 10));
    });

    test('a single slow lap near the end is not called as a drop-off', () {
      final times = [for (var i = 0; i < 10; i++) 90000 + noise[i]];
      times[8] = 91000;
      expect(StintSummary.fromLaps(laps(times)).single.tyreDropOff, isNull);
    });

    test('Boxington calls the drop-off once per stint', () {
      final times = [for (var i = 0; i < 14; i++) 90000 + noise[i] + (i >= 8 ? 1500 : 0)];
      final caller = TyreDropOffCaller();
      final stint = StintSummary.fromLaps(laps(times)).single;
      final prompt = caller.check(stint);
      expect(prompt, contains('gone off from lap 9'));
      expect(prompt, contains('after 8 laps at peak pace'));
      expect(caller.check(stint), isNull);
      expect(caller.check(StintSummary.fromLaps(laps(times.sublist(0, 8))).single), isNull);
    });
  });

  testWidgets('the practice log shows each stint with its label and results', (tester) async {
    // Tall enough that the pit-testing panel above doesn't push the
    // stints out of the lazily built list.
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: PracticeLogScreen(
          laps: [
            _lap(stint: 1, fuelStart: 100, wear: 97),
            _lap(stint: 1, fuelStart: 97, wear: 94),
            _lap(stint: 2, fuelStart: 60, tyre: 'Racing Medium'),
          ],
          roundName: 'Round 5',
          onClear: () {},
          onDeleteLap: (_) {},
        ),
      ),
    );
    expect(find.text('Round 5 Testing - Stint 1 - Fuel 100%, Tyre RS'), findsOneWidget);
    expect(find.text('Round 5 Testing - Stint 2 - Fuel 60%, Tyre RM'), findsOneWidget);
    expect(find.text('3.00%'), findsWidgets); // fuel per lap
  });
}
