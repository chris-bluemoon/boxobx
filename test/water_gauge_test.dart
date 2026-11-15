import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/hud_overlay_data.dart';
import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/models/weather_forecast.dart';
import 'package:boxbox/services/practice_lap_logger.dart';
import 'package:boxbox/services/stint_summary.dart';
import 'package:boxbox/services/water_pace_model.dart';
import 'package:boxbox/services/wet_pace_table.dart';
import 'package:boxbox/services/wet_tyre_caller.dart';

var _seq = 0;

/// A practice stint: one lap per (water, lap ms).
List<PracticeLapRecord> _run(int stint, String tyre, List<(double, int)> laps, {bool race = false}) => [
  for (final (water, ms) in laps)
    PracticeLapRecord(
      lapNumber: ++_seq,
      lapTimeMs: ms,
      tireCompound: tyre,
      fuelPercentAtLapStart: 50,
      fuelPercentAtLapEnd: 47,
      recordedAt: DateTime(2026, 11, 15, 12, _seq),
      stintNumber: stint,
      waterPercent: water,
      isRaceLap: race,
      raceNumber: race ? 1 : null,
    ),
];

/// Inters: 100 s at 0% water, +0.05 s per 1% (run 10-60%).
/// Slicks: 92 s at 0%, +0.35 s per 1% (run 5-35%).
/// They cross at 8000 / 300 = 26.7% water.
final _tested = [
  ..._run(1, 'Intermediate', [for (final w in [10.0, 25.0, 40.0, 55.0, 60.0]) (w, (100000 + 50 * w).round())]),
  ..._run(2, 'Racing Medium', [for (final w in [5.0, 15.0, 25.0, 35.0, 20.0]) (w, (92000 + 350 * w).round())]),
];

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

void main() {
  _untaggedWetTests();
  _practiceCallTests();
  _raceLapTests();
  test('the relay\'s water reading reaches the HUD data', () {
    expect(HudOverlayData.fromMap({'waterPercent': 47.5}).waterPercent, 47.5);
    expect(HudOverlayData.fromMap({}).waterPercent, isNull);
  });

  test('each lap records the mean of the water readings taken during it', () {
    final logger = PracticeLapLogger();
    logger.update(_frameAt(1));
    logger.reportWater(50);
    logger.reportWater(40);
    logger.update(_frameAt(2));
    logger.update(_frameAt(3)); // no readings on lap 2
    expect(logger.laps[0].waterPercent, 45);
    expect(logger.laps[1].waterPercent, isNull);
    expect(logger.currentWaterPercent, 40);
    final restored = PracticeLapRecord.fromMap(logger.laps[0].toMap());
    expect(restored.waterPercent, 45);
  });

  test('a stint shows the water it ran in', () {
    final stint = StintSummary.fromLaps(_run(1, 'Intermediate', [(48, 100000), (40, 100000), (21, 100000)])).first;
    expect(stint.waterLabel, 'water 48-21%');
    expect(stint.label('R5'), endsWith('Water 48-21%'));
  });

  group('pace against water', () {
    test('GT7\'s gauge lines until a crossover is measured', () {
      const model = WaterPaceModel({});
      expect(model.tyreFor(32), WeatherTyre.slicks);
      expect(model.tyreFor(34), WeatherTyre.inters);
      expect(model.tyreFor(66), WeatherTyre.inters);
      expect(model.tyreFor(67), WeatherTyre.wets);
      expect(model.crossover(WeatherTyre.slicks), (100 / 3, false));
    });

    test('testing measures where slicks take over', () {
      final model = WaterPaceModel.fromLaps(_tested);
      final (w, measured) = model.crossover(WeatherTyre.slicks);
      expect(measured, isTrue);
      expect(w, closeTo(26.7, 0.2));
      expect(model.tyreFor(25), WeatherTyre.slicks);
      expect(model.tyreFor(30), WeatherTyre.inters);
      // At 15% water slicks are 0.05*15 - 0.35*15 + 8 = 3.5 s a lap faster.
      expect(model.gainMs(WeatherTyre.inters, WeatherTyre.slicks, 15), closeTo(3500, 1));
      // Nothing near 90%: no figure.
      expect(model.gainMs(WeatherTyre.inters, WeatherTyre.slicks, 90), isNull);
      expect(model.toPromptContext()['crossovers'][0], contains('measured in testing'));
    });
  });

  group('Boxington from the gauge', () {
    final brief = WeatherForecast.tryParse('R06/R05/C03/S14/S04/R03/R04/R05')!;

    test('drying below the crossover: box for slicks when they pay back', () {
      final d = WetTyreCaller.fromWater(
        water: 15,
        lastLapWater: 18,
        forecast: brief,
        currentLap: 9,
        totalLaps: 26,
        currentCompound: 'Intermediate',
        model: WaterPaceModel.fromLaps(_tested),
        pitLossSeconds: 30,
      )!;
      expect(d.target, WeatherTyre.slicks);
      expect(d.crossoverMeasured, isTrue);
      // Dry slots run to lap 16: 8 laps x 3.5 s = 28 s < 30 s stop.
      expect(d.lapsOnTarget, 8);
      expect(d.verdict, WetVerdict.stayOut);
      final early = WetTyreCaller.fromWater(
        water: 15,
        forecast: brief,
        currentLap: 7,
        totalLaps: 26,
        currentCompound: 'Intermediate',
        model: WaterPaceModel.fromLaps(_tested),
        pitLossSeconds: 30,
      )!;
      expect(early.verdict, WetVerdict.box, reason: '10 laps x 3.5 s = 35 s');
    });

    test('the last lap has to agree, so a passing shower makes no call', () {
      expect(
        WetTyreCaller.fromWater(
          water: 20,
          lastLapWater: 40,
          forecast: brief,
          currentLap: 9,
          totalLaps: 26,
          currentCompound: 'Intermediate',
          model: const WaterPaceModel({}),
          pitLossSeconds: 30,
        ),
        isNull,
      );
    });

    test('opening spell: starting on Inters in heavy water is the plan', () {
      expect(
        WetTyreCaller.fromWater(
          water: 80,
          forecast: brief,
          currentLap: 2,
          totalLaps: 26,
          currentCompound: 'Intermediate',
          model: const WaterPaceModel({}),
          pitLossSeconds: 30,
        ),
        isNull,
      );
    });

    test('one call per time the gauge and the tyre disagree', () {
      final caller = WetTyreCaller();
      String? check(int lap, double water, String tyre) => caller.check(
        forecast: brief,
        currentLap: lap,
        totalLaps: 26,
        currentCompound: tyre,
        laps: const [],
        pitLossSeconds: 30,
        waterPercent: water,
      );
      final call = check(9, 20, 'Intermediate')!;
      expect(call, contains('water gauge: 20% water'));
      expect(call, contains("below GT7's gauge line at 33%"));
      expect(call, contains('Not tested'));
      expect(check(10, 18, 'Intermediate'), isNull, reason: 'already called');
      expect(check(11, 12, 'Racing Medium'), isNull, reason: 'on the right tyre now');
      // Rain is back over the line on slicks: a new call.
      expect(check(20, 45, 'Racing Medium'), contains('above'));
    });
  });
}

void _raceLapTests() {
  test('race laps teach the model too, without the start lap', () {
    final race = _run(3, 'Racing Medium', [(50, 200000), for (final w in [5.0, 15.0, 25.0, 35.0]) (w, (92000 + 350 * w).round())], race: true);
    final model = WaterPaceModel.fromLaps([..._tested.where((l) => l.tireCompound == 'Intermediate'), ...race]);
    expect(model.fits[WeatherTyre.slicks]!.laps, 4);
    expect(model.crossover(WeatherTyre.slicks).$2, isTrue);
  });
}

void _practiceCallTests() {
  test('practice: the gauge as information, once each time it parts from the tyre', () {
    final caller = WetTyreCaller();
    String? check(double water, String tyre, {List<PracticeLapRecord>? laps}) =>
        caller.practiceCheck(water: water, currentCompound: tyre, laps: laps ?? _tested);
    final call = check(15, 'Intermediate')!;
    expect(call, contains('information only'));
    expect(call, contains('below our measured crossover at 27%'));
    expect(call, contains('3.5s a lap faster'));
    expect(check(14, 'Intermediate'), isNull, reason: 'said once');
    expect(check(12, 'Racing Medium'), isNull, reason: 'right tyre now');
    // Untested: GT7's line, and a nudge to measure it.
    final untested = WetTyreCaller().practiceCheck(water: 50, currentCompound: 'Racing Medium', laps: const []);
    expect(untested, contains("above GT7's gauge line at 33%"));
    expect(untested, contains('would measure the crossover'));
  });
}

void _untaggedWetTests() {
  test('a wet stint left tagged dry is kept out of the dry pace', () {
    final table = WetPaceTable.fromLaps(_tested); // no weather set, water 5-60%
    expect(table.pace('DRY', WeatherTyre.inters), isNull);
    expect(table.pace('DRY', WeatherTyre.slicks), isNull);
    final dry = _run(5, 'Racing Medium', [(0, 90000), (2, 90100), (0, 89900)]);
    expect(WetPaceTable.fromLaps(dry).pace('DRY', WeatherTyre.slicks), isNotNull);
  });
}
