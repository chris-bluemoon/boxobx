import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/fuel_prediction.dart';
import 'package:boxbox/models/fused_race_state.dart';
import 'package:boxbox/models/hud_overlay_data.dart';
import 'package:boxbox/models/race_strategy.dart';
import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/models/traffic_map.dart';
import 'package:boxbox/services/pit_call_advisor.dart';
import 'package:boxbox/services/race_lap_estimator.dart';
import 'package:boxbox/services/rejoin_forecaster.dart';

TelemetryFrame _frame(int lap, {int lastLapMs = -1, int totalLaps = -1}) => TelemetryFrame(
  rpm: 0,
  speedKmh: 200,
  gear: 4,
  posX: 0,
  posY: 0,
  posZ: 0,
  lapDistance: 0,
  trackLength: 0,
  fuelPercent: 50,
  tireTemps: const [0, 0, 0, 0],
  currentLap: lap,
  totalLaps: totalLaps,
  lastLapTimeMs: lastLapMs,
);

/// Drives laps 1..[upTo] (each lap's time from [lapMs]); returns the
/// estimate on the first frame of lap [upTo] + 1.
RaceLaps? _driveTo(RaceLapEstimator e, int upTo, int Function(int lap) lapMs, {Set<int> pitLaps = const {}}) {
  RaceLaps? laps = e.update(_frame(1), pitLaps: pitLaps);
  for (var lap = 1; lap <= upTo; lap++) {
    laps = e.update(_frame(lap + 1, lastLapMs: lapMs(lap)), pitLaps: pitLaps);
  }
  return laps;
}

void main() {
  test("a lap race uses GT7's own count", () {
    final e = RaceLapEstimator()..raceLengthMinutes = 90;
    final laps = e.update(_frame(3, totalLaps: 26))!;
    expect(laps.total, 26);
    expect(laps.estimated, isFalse);
  });

  test('no time limit and no lap count: unknown', () {
    expect(RaceLapEstimator().update(_frame(3)), isNull);
  });

  test("before any clean lap, the strategy's lap count stands in", () {
    final e = RaceLapEstimator()
      ..raceLengthMinutes = 90
      ..plannedLaps = 48;
    expect(_driveTo(e, 1, (_) => 120000)!.total, 48, reason: 'lap 1 (standing start) is not pace');
  });

  test('90 minutes at 1:52: you finish the lap you are on when the clock runs out', () {
    final e = RaceLapEstimator()
      ..raceLengthMinutes = 90
      ..plannedLaps = 40;
    // 5400 s / 112 s = 48.2 -> 49 laps.
    final laps = _driveTo(e, 10, (lap) => lap == 1 ? 118000 : 112000)!;
    expect(laps.estimated, isTrue);
    // 118 + 9 x 112 = 1126 s done, 4274 s left / 112 = 38.2 -> 10 + 39 = 49.
    expect(laps.total, 49);
    expect(laps.fuelSafeTotal, 49);
  });

  test('pit laps and the standing start are left out of the pace', () {
    final e = RaceLapEstimator()..raceLengthMinutes = 60;
    final laps = _driveTo(e, 6, (lap) => lap == 1 || lap == 4 ? 140000 : 100000, pitLaps: {4})!;
    // 140 + 140 + 4 x 100 = 680 s done, 2920 s left at 100 s = 29.2 -> 6 + 30.
    expect(laps.total, 36);
  });

  test('close to tipping into an extra lap: fuel is planned for one more', () {
    final e = RaceLapEstimator()..raceLengthMinutes = 30;
    // 2 laps done, 1800 - 200 = 1600 s left at 100.5 s = 15.92 -> 18 laps,
    // and a touch quicker would make it 19.
    final laps = _driveTo(e, 2, (_) => 100000)!;
    expect(laps.total, 18);
    final tight = _driveTo(RaceLapEstimator()..raceLengthMinutes = 30, 2, (_) => 100500)!;
    expect(tight.total, 18);
    expect(tight.fuelSafeTotal, 19);
  });

  test('joining part-way through: unseen laps count at race pace', () {
    final e = RaceLapEstimator()..raceLengthMinutes = 60;
    e.update(_frame(11));
    e.update(_frame(12, lastLapMs: 100000));
    final laps = e.update(_frame(13, lastLapMs: 100000))!;
    // 12 laps done at 100 s = 1200 s, 2400 s left -> 12 + 24.
    expect(laps.total, 36);
  });

  test('a new session (lap counter back to 1) starts over', () {
    final e = RaceLapEstimator()
      ..raceLengthMinutes = 60
      ..plannedLaps = 30;
    _driveTo(e, 5, (_) => 100000);
    expect(e.update(_frame(1))!.total, 30);
  });

  test('strategy suggestion: laps for a time limit at a pace', () {
    expect(RaceLapEstimator.lapsFor(90, 112000), 49);
    expect(RaceLapEstimator.lapsFor(60, 120000), 30);
  });

  group('pit calls in a timed race', () {
    FusedRaceState state({required int lap, RaceLaps? raceLaps, int? fuelEmptyLap}) {
      const traffic = TrafficMap(trackReady: true, playerLapProgress: 300, lapSeconds: 100);
      return FusedRaceState.initial().copyWith(
        telemetry: _frame(lap),
        hud: const HudOverlayData(traffic: traffic),
        fuelPrediction: fuelEmptyLap == null
            ? FuelPrediction.insufficientData()
            : FuelPrediction(predictedEmptyLap: fuelEmptyLap, percentPerLap: 3, hasEnoughData: true),
        rejoinForecast: RejoinForecaster.forecast(traffic, measuredPitLossSeconds: 25),
        pitLapProgress: 500,
        sessionPhase: SessionPhase.driving,
        raceLaps: raceLaps,
      );
    }

    const stop = PlannedPitStop(lap: 24, tireCompound: 'Racing Medium', reasoning: '');

    test('calls the planned stop using the estimated lap count, and says it is a timed race', () {
      final call = PitCallAdvisor().check(
        state(lap: 23, raceLaps: const RaceLaps(total: 49, estimated: true)),
        plannedStops: const [stop],
        pitLapsThisSession: const {},
      );
      expect(call, isNotNull);
      expect(call!.toPrompt(), contains('timed race, about 49 laps'));
    });

    test('without any lap count there is still no call', () {
      final call = PitCallAdvisor().check(state(lap: 23), plannedStops: const [stop], pitLapsThisSession: const {});
      expect(call, isNull);
    });

    test('fuel: plans for the extra lap when the estimate is close to one more', () {
      // Runs dry on lap 50: past an estimated 49, but the clock could make it 50.
      final tight = state(
        lap: 48,
        fuelEmptyLap: 50,
        raceLaps: const RaceLaps(total: 49, estimated: true, fuelSafeTotal: 50),
      );
      expect(PitCallAdvisor().check(tight, plannedStops: const [], pitLapsThisSession: const {}), isNotNull);

      final clear = state(lap: 48, fuelEmptyLap: 50, raceLaps: const RaceLaps(total: 49, estimated: true));
      expect(PitCallAdvisor().check(clear, plannedStops: const [], pitLapsThisSession: const {}), isNull);
    });
  });
}
