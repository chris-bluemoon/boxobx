import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/fuel_prediction.dart';
import 'package:boxbox/models/fused_race_state.dart';
import 'package:boxbox/models/hud_overlay_data.dart';
import 'package:boxbox/models/race_strategy.dart';
import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/models/traffic_map.dart';
import 'package:boxbox/services/pit_call_advisor.dart';
import 'package:boxbox/services/rejoin_forecaster.dart';

const _stopLap14 = PlannedPitStop(lap: 14, tireCompound: 'Racing Soft', reasoning: '');

/// A state on [lap] of 26, our map marker [toPit] (0-1000) before the pit.
FusedRaceState _state({
  int lap = 13,
  double toPit = 200,
  List<(double, int)> carsSecondsBehind = const [(10, 1), (40, 1)],
  int? fuelEmptyLap,
  String? driverBehind,
  double? gapBehind,
  bool inPit = false,
  SessionPhase phase = SessionPhase.driving,
}) {
  final traffic = TrafficMap(
    trackReady: true,
    playerLapProgress: (500 - toPit) % 1000,
    lapSeconds: 100,
    cars: [for (final (s, n) in carsSecondsBehind) TrafficCar(lapProgress: 0, count: n, secondsBehind: s)],
  );
  return FusedRaceState.initial().copyWith(
    telemetry: TelemetryFrame(
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
      totalLaps: 26,
    ),
    hud: HudOverlayData(traffic: traffic, driverBehind: driverBehind, gapBehindSeconds: gapBehind, playerInPit: inPit),
    fuelPrediction: fuelEmptyLap == null
        ? FuelPrediction.insufficientData()
        : FuelPrediction(predictedEmptyLap: fuelEmptyLap, percentPerLap: 3, hasEnoughData: true),
    rejoinForecast: RejoinForecaster.forecast(traffic, measuredPitLossSeconds: 25),
    pitLapProgress: 500,
    sessionPhase: phase,
  );
}

void main() {
  PitCall? check(
    FusedRaceState s, {
    List<PlannedPitStop> stops = const [_stopLap14],
    Set<int> pitLaps = const {},
    PitCallAdvisor? advisor,
  }) => (advisor ?? PitCallAdvisor()).check(s, plannedStops: stops, pitLapsThisSession: pitLaps);

  test('silent outside the planned stop window when fuel is fine', () {
    expect(check(_state(lap: 10)), isNull);
    expect(check(_state(lap: 17)), isNull);
  });

  test('calls within 2 laps of the planned stop, with the planned tyre', () {
    final call = check(_state(lap: 12))!;
    expect(call.reason, PitCallReason.plannedStop);
    expect(call.advice, PitCallAdvice.boxNow);
    expect(call.toPrompt(), contains('planned pit stop is lap 14 (fit Racing Soft)'));
  });

  test('says whether we come out ahead of the car behind, named from the leaderboard', () {
    // Car 40s behind, 25s pit loss: still 15s behind us after the stop.
    final ahead = check(_state(carsSecondsBehind: const [(40, 1)], driverBehind: 'Chuck_E82', gapBehind: 40.3))!;
    expect(ahead.carBehindName, 'Chuck_E82');
    expect(ahead.carBehindSecondsAfterStop, closeTo(15, 1e-9));
    expect(ahead.toPrompt(), contains('come out ahead of Chuck_E82'));

    // Car 10s behind: gets past while we're stopped.
    final behind = check(_state(carsSecondsBehind: const [(10, 1), (60, 1)], driverBehind: 'Chuck_E82'))!;
    expect(behind.carBehindSecondsAfterStop, closeTo(-15, 1e-9));
    expect(behind.toPrompt(), contains('Chuck_E82 gets past'));
  });

  test("doesn't put a leaderboard name on the map's car when their gaps disagree", () {
    final call = check(_state(carsSecondsBehind: const [(10, 1)], driverBehind: 'Chuck_E82', gapBehind: 30))!;
    expect(call.carBehindName, isNull);
    expect(call.toPrompt(), contains('the car behind'));
  });

  test('stay out one more when we would rejoin stuck right behind a car', () {
    // Car 24s behind, 25s loss: we'd rejoin 1s behind it.
    final call = check(_state(lap: 13, carsSecondsBehind: const [(24, 1)]))!;
    expect(call.advice, PitCallAdvice.stayOutOneMore);
    expect(call.toPrompt(), contains('STAY OUT ONE MORE LAP'));
  });

  test('forced on the last lap of the window even if we would rejoin behind a car', () {
    final call = check(_state(lap: 16, carsSecondsBehind: const [(24, 1)]))!;
    expect(call.advice, PitCallAdvice.boxNowForced);
  });

  test('no planned-stop call once we have already stopped in its window', () {
    expect(check(_state(lap: 15), pitLaps: {14, 15}), isNull);
  });

  test('fuel call when fuel runs out within 2 laps, forced when it runs out next lap', () {
    final soon = check(_state(lap: 20, fuelEmptyLap: 22), stops: const [])!;
    expect(soon.reason, PitCallReason.fuel);
    expect(soon.advice, PitCallAdvice.boxNow);
    expect(soon.toPrompt(), contains('fuel runs out on lap 22'));
    expect(
      check(_state(lap: 21, fuelEmptyLap: 22, carsSecondsBehind: const [(24, 1)]), stops: const [])!.advice,
      PitCallAdvice.boxNowForced,
    );
  });

  test('no fuel call when the prediction is past the finish (makes it to the flag)', () {
    expect(check(_state(lap: 25, fuelEmptyLap: 28), stops: const []), isNull);
    expect(check(_state(lap: 3, fuelEmptyLap: 144), stops: const []), isNull);
  });

  test('called once per lap, at the point a little before the pit entry', () {
    final advisor = PitCallAdvisor();
    expect(check(_state(lap: 13, toPit: 600), advisor: advisor), isNull, reason: 'too early in the lap');
    expect(check(_state(lap: 13, toPit: 50), advisor: advisor), isNull, reason: 'too late to react');
    expect(check(_state(lap: 13, toPit: 250), advisor: advisor), isNotNull);
    expect(check(_state(lap: 13, toPit: 150), advisor: advisor), isNull, reason: 'already called this lap');
    expect(check(_state(lap: 14, toPit: 250), advisor: advisor), isNotNull, reason: 'next lap, still due');
  });

  test('silent while paused, off track, in the pits, or on the last lap', () {
    expect(check(_state(phase: SessionPhase.paused)), isNull);
    expect(check(_state(phase: SessionPhase.offTrack)), isNull);
    expect(check(_state(inPit: true)), isNull);
    expect(check(_state(lap: 26, fuelEmptyLap: 26), stops: const []), isNull);
  });
}
