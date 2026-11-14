import 'dart:convert';
import 'dart:math' as math;

import 'package:boxbox/models/app_mode.dart';
import 'package:boxbox/models/sector_map.dart';
import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/screens/corner_report_screen.dart';
import 'package:boxbox/services/corner_report.dart';
import 'package:boxbox/services/sector_calculator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A circular test track (r = 300 m) with two hard corners -- speed dips
/// from 50 to 20 m/s at a quarter and three quarters of the lap, braking
/// (80%) for [brakeLead] of the lap before each -- driven at 60 packets a
/// second, starting mid-lap.
class _Lap {
  double dip2 = 30; // how much slower corner 2 is taken
  double brakeLead2 = 0.06; // how early (lap fraction) braking starts for corner 2

  double speed(double f) =>
      50 - 30 * math.exp(-math.pow((f - 0.25) / 0.03, 2)) - dip2 * math.exp(-math.pow((f - 0.75) / 0.03, 2));

  double brake(double f) => (f > 0.25 - 0.06 && f < 0.25) || (f > 0.75 - brakeLead2 && f < 0.75) ? 80 : 0;
}

class _Driver {
  final SectorCalculator calc;
  final _Lap lap = _Lap();
  static const radius = 300.0;
  static const circumference = 2 * math.pi * radius;
  int packet = 1000, currentLap = 1, lastLapMs = -1;
  double distance = circumference / 2, lapStartPacket = 1000;

  _Driver(this.calc);

  void drive(int laps) {
    var completed = 0;
    while (completed < laps) {
      packet++;
      final f = distance / circumference;
      distance += lap.speed(f) / 60;
      if (distance >= circumference) {
        final over = distance - circumference;
        final crossing = packet - over / (lap.speed(0) / 60);
        lastLapMs = ((crossing - lapStartPacket) / 60 * 1000).round();
        lapStartPacket = crossing;
        distance = over;
        currentLap++;
        completed++;
      }
      final angle = distance / radius;
      final g = distance / circumference;
      calc.evaluate(
        TelemetryFrame(
          rpm: 0,
          speedKmh: lap.speed(g) * 3.6,
          gear: 3,
          posX: radius * math.cos(angle),
          posY: 0,
          posZ: radius * math.sin(angle),
          lapDistance: 0,
          trackLength: 0,
          fuelPercent: 50,
          tireTemps: const [0, 0, 0, 0],
          currentLap: currentLap,
          lastLapTimeMs: lastLapMs,
          packetId: packet,
          brakePercent: lap.brake(g),
        ),
      );
    }
  }

  CornerReport? report() {
    final trace = calc.lastLapTrace, reference = calc.lastLapComparedTo;
    if (trace == null || reference == null) return null;
    return CornerReport.compare(trace, reference, calc.corners);
  }
}

void main() {
  _Driver referenceSet() => _Driver(SectorCalculator(persist: (_) async {}))..drive(2);

  test('the reference lap finds the two corners, numbered in lap order, at their slowest points', () {
    final d = referenceSet();
    final corners = d.calc.corners;
    expect(corners.map((c) => c.number), [1, 2]);
    double angleOf(double x, double z) => (math.atan2(z, x) / (2 * math.pi) + 1) % 1;
    expect(angleOf(corners[0].x, corners[0].z), closeTo(0.25, 0.01));
    expect(angleOf(corners[1].x, corners[1].z), closeTo(0.75, 0.01));
  });

  test('the same lap again: nothing lost anywhere, same speeds and brake points', () {
    final d = referenceSet()..drive(1);
    final report = d.report()!;
    expect(report.corners, hasLength(2));
    for (final c in report.corners) {
      expect(c.timeDeltaMs.abs(), lessThan(40));
      expect(c.minDeltaKmh.abs(), lessThan(1));
      expect(c.brakeDeltaMeters!.abs(), lessThan(1.5));
      expect(c.lap.braking!.peakPercent, 80);
    }
    expect(report.biggestLoss?.timeDeltaMs ?? 0, lessThan(40));
  });

  test('braking earlier and slower into corner 2: it is the biggest loss, with the reasons', () {
    final d = referenceSet();
    d.lap
      ..dip2 = 34
      ..brakeLead2 = 0.07; // ~19 m earlier
    d.drive(1);
    final report = d.report()!;
    final c1 = report.corners[0], c2 = report.corners[1];

    expect(report.biggestLoss, same(c2));
    expect(c2.timeDeltaMs, greaterThan(150));
    expect(c1.timeDeltaMs.abs(), lessThan(40));
    expect(c2.brakeDeltaMeters, closeTo(-0.01 * _Driver.circumference, 3));
    expect(c2.minDeltaKmh, closeTo(-4 * 3.6, 1.5));
    expect(c2.describe(), allOf(contains('corner 2'), contains('lost'), contains('earlier'), contains('lower')));

    // The stretches add up to the whole lap's gap.
    final sum = report.corners.fold<double>(0, (s, c) => s + c.timeDeltaMs);
    expect(sum, closeTo(report.lapDeltaMs, 1));
  });

  test('corner numbering stays put when a faster lap becomes the reference', () {
    final d = referenceSet();
    final before = d.calc.corners.map((c) => (c.x, c.z)).toList();
    d.lap.dip2 = 25; // quicker through corner 2
    d.drive(1);
    expect(d.calc.lastLapComparedTo!.lapTimeMs, greaterThan(d.lastLapMs), reason: 'it became the new reference');
    expect(d.calc.corners.map((c) => (c.x, c.z)).toList(), before);
  });

  test('corners and speed/brake traces are saved and reloaded with the layout', () {
    List<SectorMap> saved = [];
    _Driver(SectorCalculator(persist: (m) async => saved = m)).drive(2);
    final reloaded = SectorMap.fromMap(jsonDecode(jsonEncode(saved.single.toMap())) as Map<String, dynamic>);
    expect(reloaded.corners, hasLength(2));
    expect(reloaded.references.values.single.hasSpeedAndBrake, isTrue);
  });

  test("Gunther's corner call is for Time Trialing only", () {
    expect(AppMode.timeTrial.cornerCalls, isTrue);
    expect(AppMode.race.cornerCalls, isFalse);
    expect(AppMode.practice.cornerCalls, isFalse);
  });

  testWidgets('the report screen lists corners, sorts by biggest loss, and zooms the map on a tap', (tester) async {
    tester.view.physicalSize = const Size(1180, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final d = referenceSet();
    d.lap.dip2 = 34;
    d.drive(1);
    final report = d.report()!;

    await tester.pumpWidget(MaterialApp(home: CornerReportScreen(report: report)));
    expect(find.text('C1'), findsOneWidget);
    expect(find.text('C2'), findsOneWidget);
    double y(String t) => tester.getTopLeft(find.text(t)).dy;
    expect(y('C1'), lessThan(y('C2')), reason: 'track order');

    await tester.tap(find.text('BIGGEST LOSS'));
    await tester.pump();
    expect(y('C2'), lessThan(y('C1')), reason: 'biggest loss first');

    await tester.tap(find.text('C2'));
    await tester.pump();
    expect(find.textContaining('brake point: white = last lap'), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(820, 1180); // portrait
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
