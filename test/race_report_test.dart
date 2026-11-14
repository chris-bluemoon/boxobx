import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/models/race_strategy.dart';
import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/models/time_trial_lap.dart';
import 'package:boxbox/screens/race_reports_screen.dart';
import 'package:boxbox/services/practice_lap_logger.dart';
import 'package:boxbox/services/race_report.dart';

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
  required int race,
  required int stint,
  required double fuelStart,
  double fuelEnd = double.nan,
  int lapTimeMs = 91000,
  String tyre = 'Racing Medium',
  bool pit = false,
  int? position,
}) => PracticeLapRecord(
  lapNumber: 1,
  lapTimeMs: lapTimeMs,
  tireCompound: tyre,
  fuelPercentAtLapStart: fuelStart,
  fuelPercentAtLapEnd: fuelEnd.isNaN ? fuelStart - 3 : fuelEnd,
  recordedAt: DateTime(2026, 11, 14, 18, 5),
  isPitLap: pit,
  stintNumber: stint,
  isRaceLap: true,
  raceNumber: race,
  position: position,
);

/// A 6-lap race: 3 laps on Medium, a stop on lap 3 refuelling +40% onto
/// Soft, then 3 more laps.
List<PracticeLapRecord> _race(int race) => [
  _lap(race: race, stint: 1, fuelStart: 60, position: 5),
  _lap(race: race, stint: 1, fuelStart: 57, position: 4),
  _lap(race: race, stint: 2, fuelStart: 54, fuelEnd: 91, lapTimeMs: 115000, pit: true, position: 6),
  _lap(race: race, stint: 2, fuelStart: 91, lapTimeMs: 94000, pit: true, tyre: 'Racing Soft', position: 6),
  _lap(race: race, stint: 2, fuelStart: 88, lapTimeMs: 90500, tyre: 'Racing Soft', position: 5),
  _lap(race: race, stint: 2, fuelStart: 85, lapTimeMs: 90000, tyre: 'Racing Soft', position: 3),
];

void main() {
  group('races in the log', () {
    test('each time out on track in Race Mode is a new race; practice laps have none', () {
      final logger = PracticeLapLogger();
      logger.update(_frame(1, 100));
      logger.update(_frame(2, 97));
      expect(logger.laps.last.raceNumber, isNull, reason: 'practice');

      logger.isRaceMode = true;
      logger.currentPosition = 4;
      logger.update(_frame(3, 94));
      logger.update(_frame(4, 91));
      expect(logger.laps.skip(1).map((l) => l.raceNumber), [1, 1]);
      expect(logger.laps.last.position, 4);

      logger.startNewSession(); // back to the garage, out again
      logger.update(_frame(1, 100));
      logger.update(_frame(2, 97));
      expect(logger.laps.last.raceNumber, 2);
    });

    test('reports are grouped per race, newest first', () {
      final reports = RaceReport.fromLaps([..._race(1), ..._race(2)]);
      expect(reports.map((r) => r.raceNumber), [2, 1]);
      expect(RaceReport.fromLaps([_lap(race: 1, stint: 1, fuelStart: 50)].map((l) => l).toList()), hasLength(1));
    });
  });

  group('a race report', () {
    final report = RaceReport.fromLaps(_race(1)).single;

    test('result: total time, finishing position, best lap', () {
      expect(report.lapCount, 6);
      expect(report.totalTimeMs, 91000 + 91000 + 115000 + 94000 + 90500 + 90000);
      expect(RaceReport.formatTotal(report.totalTimeMs), '9:31.500');
      expect(report.finishingPosition, 3);
      expect(report.bestLapMs, 90000);
    });

    test('pit stops: the lap, the tyre fitted and the fuel added', () {
      final stop = report.pitStops.single;
      expect(stop.lap, 3);
      expect(stop.tyreFitted, 'Racing Soft');
      expect(stop.fuelAddedPercent, closeTo(37, 0.01)); // 54 -> 91 during the stop lap
      expect(report.fuelPerLapPercent, 3.0);
    });

    test('plan vs actual: stops matched in order, early/late and tyre', () {
      const strategy = RaceStrategy(
        pitStops: [
          PlannedPitStop(lap: 4, tireCompound: 'Racing Soft', reasoning: ''),
          PlannedPitStop(lap: 9, tireCompound: 'Racing Medium', reasoning: ''),
        ],
        startingTireCompound: 'Racing Medium',
        summary: '',
        assumedPercentPerLap: 3.2,
      );
      final compared = report.comparedWith(strategy);
      expect(compared, hasLength(2));
      expect(compared.first.lapDifference, -1, reason: 'stopped a lap early');
      expect(compared.first.tyreAsPlanned, isTrue);
      expect(compared.last.actual, isNull, reason: 'second planned stop not made');
    });

    test('pace against the time-trial best, overall and per stint', () {
      final tt = TimeTrialLap(lapTimeMs: 89000, tireCompound: 'Racing Soft', recordedAt: DateTime(2026));
      // Clean laps: 91.0, 91.0, 90.5, 90.0 -> gaps 2.0, 2.0, 1.5, 1.0
      expect(RaceReport.averageGapSeconds(report.laps, tt), closeTo(1.625, 1e-9));
      expect(RaceReport.averageGapSeconds(report.laps, null), isNull);
    });
  });

  testWidgets('the reports list and a race report render', (tester) async {
    tester.view.physicalSize = const Size(1640, 2360);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const strategy = RaceStrategy(
      pitStops: [PlannedPitStop(lap: 3, tireCompound: 'Racing Soft', reasoning: '')],
      startingTireCompound: 'Racing Medium',
      summary: '',
      assumedPercentPerLap: 3.0,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RaceReportsScreen(
          laps: [..._race(1), ..._race(2)],
          strategy: strategy,
          timeTrialBest: TimeTrialLap(lapTimeMs: 89000, tireCompound: 'Racing Soft', recordedAt: DateTime(2026)),
          roundName: 'Round 5',
        ),
      ),
    );
    expect(find.textContaining('Race 2 ·'), findsOneWidget);
    expect(find.textContaining('Race 1 ·'), findsOneWidget);

    await tester.tap(find.textContaining('Race 1 ·'));
    await tester.pumpAndSettle();
    expect(find.text('9:31.500'), findsOneWidget);
    expect(find.text('P3'), findsWidgets);
    expect(find.text('on time ✓'), findsOneWidget);
    expect(find.textContaining('Lap 3: Soft, +37% fuel'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
