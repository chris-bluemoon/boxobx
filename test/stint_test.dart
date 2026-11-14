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
