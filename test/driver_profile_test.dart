// Boxington learning the driver: spins from the telemetry, logged on
// the lap with the corner, a profile over every round (wet against dry,
// places, corners that keep catching them out) and a race diary -- all
// put in front of Boxington.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:boxbox/models/fused_race_state.dart';
import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/services/driver_profile.dart';
import 'package:boxbox/services/groq_service.dart';
import 'package:boxbox/services/practice_lap_logger.dart';
import 'package:boxbox/services/spin_detector.dart';

/// A car driven through the detector, frame by frame at 60 Hz.
class _Car {
  final SpinDetector detector = SpinDetector();
  final List<Spin> spins = [];
  final double sign; // GT7's yaw sign against the travel heading's
  double heading = 0;
  int packet = 0;

  _Car({this.sign = -1});

  /// [seconds] at [speedKmh], the travel heading turning at [turnRate]
  /// rad/s and the car rotating at [yawRate] (default: with it).
  void drive({required double seconds, double speedKmh = 120, double turnRate = 0, double? yawRate}) {
    for (var i = 0; i < (seconds * 60).round(); i++) {
      heading += turnRate / 60;
      final ms = speedKmh / 3.6;
      final spin = detector.update(TelemetryFrame(
        rpm: 6000, speedKmh: speedKmh, gear: 4, posX: 0, posY: 0, posZ: 0, lapDistance: 0, trackLength: 0,
        fuelPercent: 50, tireTemps: const [80, 80, 80, 80], currentLap: 3, packetId: packet++,
        velocityX: ms * math.cos(heading), velocityZ: ms * math.sin(heading), yawRate: sign * (yawRate ?? turnRate),
      ));
      if (spin != null) spins.add(spin);
    }
  }
}

PracticeLapRecord _lap(int n, {int ms = 92000, String tyre = 'Racing Hard', double? water, List<int>? spins,
        int? race, int? position, double? lockup, bool pit = false, DateTime? at}) =>
    PracticeLapRecord(
      lapNumber: n, lapTimeMs: ms, tireCompound: tyre, fuelPercentAtLapStart: 90, fuelPercentAtLapEnd: 86,
      recordedAt: at ?? DateTime(2026, 11, 16, 15, n), waterPercent: water, spinCorners: spins,
      raceNumber: race, isRaceLap: race != null, position: position, lockupPercent: lockup, isPitLap: pit,
      stintNumber: 1,
    );

void main() {
  group('spins', () {
    test('normal cornering, hairpins included, is not a spin -- whichever way GT7 signs the yaw', () {
      for (final sign in [1.0, -1.0]) {
        final car = _Car(sign: sign)
          ..drive(seconds: 4, turnRate: 0.5) // long corners: it learns the sign
          ..drive(seconds: 3, turnRate: -0.6)
          ..drive(seconds: 4, speedKmh: 45, turnRate: 1.0); // a hairpin, 230 degrees
        expect(car.detector.calibrated, isTrue);
        expect(car.spins, isEmpty, reason: 'sign $sign');
      }
    });

    test('rotating round while still sliding the same way is a spin, called once', () {
      final car = _Car()
        ..drive(seconds: 4, turnRate: 0.5)
        // The car swaps ends in about a second, sliding on in a straight line.
        ..drive(seconds: 1, speedKmh: 90, yawRate: 3.5)
        ..drive(seconds: 1, speedKmh: 40, yawRate: 2);
      expect(car.spins, hasLength(1));
      expect(car.spins.single.speedKmh, greaterThanOrEqualTo(90));
    });

    test('before it has seen any cornering it calls nothing', () {
      final car = _Car()..drive(seconds: 1, speedKmh: 90, yawRate: 3.5);
      expect(car.spins, isEmpty);
    });

    test('a spin goes on the lap with its corner; earlier laps say not tracked', () {
      final logger = PracticeLapLogger();
      TelemetryFrame f(int lap, int last) => TelemetryFrame(rpm: 0, speedKmh: 100, gear: 3, posX: 0, posY: 0, posZ: 0,
          lapDistance: 0, trackLength: 0, fuelPercent: 50, tireTemps: const [80, 80, 80, 80], currentLap: lap,
          lastLapTimeMs: last);
      logger.update(f(1, -1));
      logger.reportSpin(4);
      logger.update(f(2, 95000));
      logger.update(f(3, 92000));
      expect(logger.laps[0].spinCorners, [4]);
      expect(logger.laps[1].spinCorners, isEmpty);
      final old = PracticeLapRecord.fromMap(logger.laps[0].toMap()..remove('spinCorners'));
      expect(old.spinCorners, isNull);
    });
  });

  group('the profile', () {
    DriverProfile profile() => DriverProfile.fromRounds([
          ProfileRound(round: 'Round 4', track: 'Alsace - Village', laps: [
            for (var n = 1; n <= 10; n++) _lap(n, race: 1, position: n == 1 ? 8 : 5, spins: const [], lockup: 1.0,
                at: DateTime(2026, 11, 9, 15, n)),
          ]),
          ProfileRound(round: 'Round 5', track: 'Nürburgring Sprint', laps: [
            for (var n = 1; n <= 6; n++) _lap(n, ms: 91000, spins: const [], lockup: 1.2), // dry practice
            for (var n = 7; n <= 16; n++)
              _lap(n, ms: 100000, tyre: 'Intermediate', water: 50, race: 2, position: n == 7 ? 9 : 12,
                  spins: n == 9 || n == 12 ? const [3] : (n == 14 ? const [0] : const []), lockup: 4.0),
          ]),
        ]);

    test('wet against dry: spins, lock-ups, pace and places', () {
      final p = profile();
      expect(p.wet.laps, 10);
      expect(p.wet.spins, 3);
      expect(p.wet.spinsPer10Laps, 3.0);
      expect(p.dry.spinsPer10Laps, 0);
      final lines = p.lines();
      expect(lines, contains('Wet: 3.0 spins per 10 laps, locking a wheel 4.0% of braking.'));
      expect(lines, contains('Wet pace at Nürburgring Sprint: 9.9% slower than dry.'));
      expect(lines, contains('Wet races (1): loses 3.0 places from lap 1 to the flag on average.'));
      expect(lines, contains('Dry races (1): gains 3.0 places from lap 1 to the flag on average.'));
      expect(lines, contains('Keeps spinning at Nürburgring Sprint corner 3 (2 times).'));
    });

    test('the race diary, newest first', () {
      final diary = profile().diary;
      expect(diary.first.describe(), startsWith('16 Nov, Nürburgring Sprint, wet: 10 laps, P9 after lap 1, finished P12, 0 stops, 3 spins (corner 3 x2)'));
      expect(diary.last.describe(), startsWith('9 Nov, Alsace - Village, dry: 10 laps, P8 after lap 1, finished P5, 0 stops, no spins'));
    });

    test("Boxington's prompt carries it", () async {
      String? sent;
      final groq = GroqService('test', client: MockClient.streaming((request, body) async {
        sent = utf8.decode(await body.toBytes());
        return http.StreamedResponse(Stream.value(utf8.encode('data: [DONE]\n\n')), 200);
      }))
        ..driverProfile = profile().toPrompt();
      await groq.streamResponse(driverUtterance: 'how am I doing', raceState: FusedRaceState.initial()).toList();
      final system = ((jsonDecode(sent!) as Map)['messages'] as List).first['content'] as String;
      expect(system, contains('Your driver --'));
      expect(system, contains('Keeps spinning at Nürburgring Sprint corner 3'));
      expect(system, contains('Recent races (newest first):'));
    });
  });
}
