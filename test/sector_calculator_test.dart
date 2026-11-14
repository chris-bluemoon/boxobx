import 'dart:convert';
import 'dart:math' as math;

import 'package:boxbox/models/sector_map.dart';
import 'package:boxbox/models/sector_state.dart';
import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/models/time_trial_lap.dart';
import 'package:boxbox/services/sector_calculator.dart';
import 'package:flutter_test/flutter_test.dart';

/// A circular test track (radius 300 m), start/finish at angle 0, driven
/// anticlockwise (or clockwise when [reverse]) at 60 packets a second.
class _Driver {
  final SectorCalculator calc;
  final bool reverse;
  double Function(double fraction) speedAt; // m/s at lap fraction
  int carCode = 0;
  static const radius = 300.0;
  static const circumference = 2 * math.pi * radius;

  int packet = 1000;
  int lap = 1;
  double distance; // along the current lap
  int lastLapMs = -1;
  double lapStartPacket = 1000;
  final List<SectorState> states = [];

  _Driver(this.calc, {this.reverse = false, double Function(double)? speedAt, double startFraction = 0.5})
    : speedAt = speedAt ?? ((_) => 40),
      distance = startFraction * circumference;

  TelemetryFrame _frame() {
    final angle = (reverse ? -1 : 1) * distance / radius;
    return TelemetryFrame(
      rpm: 0,
      speedKmh: 0,
      gear: 3,
      posX: radius * math.cos(angle),
      posY: 0,
      posZ: radius * math.sin(angle),
      lapDistance: 0,
      trackLength: 0,
      fuelPercent: 50,
      tireTemps: const [0, 0, 0, 0],
      currentLap: lap,
      lastLapTimeMs: lastLapMs,
      packetId: packet,
      carCode: carCode,
    );
  }

  /// Drives until [laps] more laps have completed; [extraPackets] are
  /// added to the clock once mid-lap (a pause GT7 doesn't count).
  void drive(int laps, {int extraPackets = 0}) {
    var completed = 0;
    var paused = false;
    while (completed < laps) {
      packet++;
      distance += speedAt(distance / circumference) / 60;
      if (!paused && extraPackets > 0 && distance > circumference / 2) {
        packet += extraPackets;
        lapStartPacket += extraPackets;
        paused = true;
      }
      if (distance >= circumference) {
        // The line was crossed part-way through this packet.
        final over = distance - circumference;
        final crossing = packet - over / (speedAt(0) / 60);
        lastLapMs = ((crossing - lapStartPacket) / 60 * 1000).round();
        lapStartPacket = crossing;
        distance = over;
        lap++;
        completed++;
        paused = false;
      }
      states.add(calc.evaluate(_frame()));
    }
  }

  List<int>? get lastSectors => states.last.lastLapSectorsMs;
}

void main() {
  test('the first full lap teaches the lines, and is split itself: thirds at constant speed, adding up to the lap', () {
    final saved = <List<SectorMap>>[];
    final calc = SectorCalculator(persist: (m) async => saved.add(m));
    final driver = _Driver(calc);

    driver.drive(1); // joined mid-lap: not timed
    expect(driver.states.last.lapJustCompleted, isTrue);
    expect(driver.lastSectors, isNull);
    expect(driver.states.last.mapped, isFalse);

    driver.drive(1); // first full lap: learns the lines and is split
    final sectors = driver.lastSectors!;
    expect(sectors.reduce((a, b) => a + b), driver.lastLapMs);
    for (final s in sectors) {
      expect(s, closeTo(driver.lastLapMs / 3, 60));
    }
    expect(saved.last, hasLength(1), reason: 'one layout saved');
    expect(driver.states.last.mapped, isTrue);
  });

  test('live: the sector in progress advances and completed splits appear during the lap', () {
    final calc = SectorCalculator(persist: (_) async {});
    final driver = _Driver(calc, startFraction: 0.9)..drive(2);
    final lapStates = <SectorState>[];
    final from = driver.states.length;
    driver.drive(1);
    lapStates.addAll(driver.states.sublist(from, driver.states.length - 1));
    expect(lapStates.map((s) => s.currentSectorIndex).toSet(), {0, 1, 2});
    expect(lapStates.last.currentLapSplitsMs, hasLength(2));
  });

  test('a slow first third shows up as a long S1', () {
    final calc = SectorCalculator(persist: (_) async {});
    final driver = _Driver(calc, speedAt: (f) => f < 1 / 3 ? 20 : 40)..drive(2);
    final sectors = driver.lastSectors!;
    expect(sectors[0], greaterThan(sectors[1] * 1.8));
    expect(sectors[1], closeTo(sectors[2], 60));
    expect(sectors.reduce((a, b) => a + b), driver.lastLapMs);
  });

  test('saved lines are recognised on the next visit, so the first full lap is split without learning again', () {
    final first = SectorCalculator(persist: (_) async {});
    _Driver(first).drive(2);

    final saved = <List<SectorMap>>[];
    final next = SectorCalculator(persist: (m) async => saved.add(m))..seedMaps(first.maps);
    final driver = _Driver(next)..drive(2);
    expect(driver.lastSectors, isNotNull);
    expect(saved, isEmpty, reason: 'same layout -- nothing new learned');
  });

  test('the reverse layout (same line, other direction) gets lines of its own', () {
    final first = SectorCalculator(persist: (_) async {});
    _Driver(first).drive(2);

    final reverse = SectorCalculator(persist: (_) async {})..seedMaps(first.maps);
    final driver = _Driver(reverse, reverse: true)..drive(2);
    expect(reverse.maps, hasLength(2));
    expect(driver.lastSectors!.reduce((a, b) => a + b), driver.lastLapMs);
  });

  test("a lap whose clock disagrees with GT7's lap time (paused mid-lap) gets no sectors rather than wrong ones", () {
    final calc = SectorCalculator(persist: (_) async {});
    final driver = _Driver(calc)..drive(2);
    expect(driver.lastSectors, isNotNull);
    driver.drive(1, extraPackets: 300); // 5 s on the packet clock, not in GT7's lap time
    expect(driver.lastSectors, isNull);
    driver.drive(1);
    expect(driver.lastSectors, isNotNull, reason: 'the next clean lap is split again');
  });

  test('leaving the track forgets the layout; the next session recognises it again', () {
    final calc = SectorCalculator(persist: (_) async {});
    _Driver(calc).drive(2);
    calc.reset();
    expect(calc.state.mapped, isFalse);
    final driver = _Driver(calc)..drive(2);
    expect(driver.lastSectors, isNotNull);
    expect(calc.maps, hasLength(1));
  });

  test('best sectors and the ideal lap', () {
    final laps = [
      [30000, 40000, 20000],
      null,
      [29000, 41000, 20500],
    ];
    expect(SectorState.bestSectors(laps), [29000, 40000, 20000]);
    expect(SectorState.idealLapMs(laps), 89000);
    expect(SectorState.idealLapMs([null]), isNull);
    expect(SectorState.format(32104), '32.104');
    expect(SectorState.format(62104), '1:02.104');
  });

  test('sector times are saved with laps and survive a reload; older laps without them still load', () {
    final tt = TimeTrialLap(
      lapTimeMs: 90000,
      tireCompound: 'Racing Soft',
      recordedAt: DateTime(2026),
      sectorsMs: const [30000, 40000, 20000],
    );
    expect(TimeTrialLap.fromMap(tt.toMap()).sectorsMs, [30000, 40000, 20000]);
    final old = Map.of(tt.toMap())..remove('sectorsMs');
    expect(TimeTrialLap.fromMap(old).sectorsMs, isNull);

    final lap = PracticeLapRecord(
      lapNumber: 1,
      lapTimeMs: 90000,
      tireCompound: 'Racing Soft',
      fuelPercentAtLapStart: 100,
      fuelPercentAtLapEnd: 97,
      recordedAt: DateTime(2026),
      sectorsMs: const [30000, 40000, 20000],
    );
    expect(PracticeLapRecord.fromMap(lap.toMap()).sectorsMs, [30000, 40000, 20000]);
    expect(lap.withTireWearPercent(80).sectorsMs, [30000, 40000, 20000]);
  });

  group('live delta', () {
    // Delta on every frame of the next lap.
    List<int?> deltasOverLap(_Driver d) {
      final from = d.states.length;
      d.drive(1);
      return [for (final st in d.states.sublist(from, d.states.length - 1)) st.liveDeltaMs];
    }

    test('nothing to compare with until a clean lap has set the reference', () {
      final calc = SectorCalculator(persist: (_) async {});
      final d = _Driver(calc);
      d.drive(1);
      expect(d.states.map((s) => s.liveDeltaMs).whereType<int>(), isEmpty);
      final firstFull = deltasOverLap(d);
      expect(firstFull.whereType<int>(), isEmpty, reason: 'the learning lap has nothing to compare with');
      expect(d.states.last.referenceLapMs, d.lastLapMs);
    });

    test('the same pace reads about zero all the way round', () {
      final calc = SectorCalculator(persist: (_) async {});
      final d = _Driver(calc)..drive(2);
      final deltas = deltasOverLap(d).whereType<int>().toList();
      expect(deltas.length, greaterThan(2000));
      expect(
        deltas.every((ms) => ms.abs() < 40),
        isTrue,
        reason: 'max ${deltas.reduce((a, b) => a.abs() > b.abs() ? a : b)}',
      );
    });

    test('slower through the first half: the delta grows there, then holds; the reference is kept', () {
      final calc = SectorCalculator(persist: (_) async {});
      final d = _Driver(calc)..drive(2);
      final reference = d.states.last.referenceLapMs;
      d.speedAt = (f) => f < 0.5 ? 36 : 40;
      final deltas = deltasOverLap(d).whereType<int>().toList();
      final quarter = deltas[deltas.length ~/ 4];
      final half = deltas[deltas.length ~/ 2];
      final end = deltas.last;
      expect(quarter, greaterThan(1000));
      expect(half, greaterThan(quarter));
      expect(end, closeTo(half, 200));
      expect(d.states.last.referenceLapMs, reference);
    });

    test('a faster lap reads negative and becomes the new reference', () {
      final calc = SectorCalculator(persist: (_) async {});
      final d = _Driver(calc)..drive(2);
      final reference = d.states.last.referenceLapMs!;
      d.speedAt = (_) => 44;
      final deltas = deltasOverLap(d).whereType<int>().toList();
      expect(deltas.last, lessThan(-3000));
      expect(d.states.last.referenceLapMs, lessThan(reference));
      d.speedAt = (_) => 44;
      expect(deltasOverLap(d).whereType<int>().every((ms) => ms.abs() < 40), isTrue);
    });

    test('a different car has its own reference', () {
      final calc = SectorCalculator(persist: (_) async {});
      final d = _Driver(calc)..drive(2);
      d.carCode = 3218;
      expect(deltasOverLap(d).whereType<int>(), isEmpty);
      expect(deltasOverLap(d).whereType<int>(), isNotEmpty);
    });

    test('references are saved with the lines and used on the next visit', () {
      List<SectorMap> saved = [];
      final first = SectorCalculator(persist: (m) async => saved = m);
      _Driver(first).drive(2);
      final reloaded = [
        for (final m in saved) SectorMap.fromMap(jsonDecode(jsonEncode(m.toMap())) as Map<String, dynamic>),
      ];
      expect(reloaded.single.references, hasLength(1));

      final next = SectorCalculator(persist: (_) async {})..seedMaps(reloaded);
      final d = _Driver(next)..drive(1);
      final deltas = deltasOverLap(d).whereType<int>().toList();
      expect(deltas, isNotEmpty);
      expect(deltas.every((ms) => ms.abs() < 40), isTrue);
    });
  });

  test('laps outside Time Trialing never set the reference', () {
    final calc = SectorCalculator(persist: (_) async {})..recordsReference = false;
    final d = _Driver(calc)..drive(3);
    expect(d.lastSectors, isNotNull, reason: 'still split into sectors');
    expect(d.states.last.referenceLapMs, isNull);

    calc.recordsReference = true;
    d.drive(1);
    expect(d.states.last.referenceLapMs, d.lastLapMs);
    calc.recordsReference = false;
    d.speedAt = (_) => 44;
    d.drive(1);
    expect(d.states.last.referenceLapMs, greaterThan(d.lastLapMs), reason: 'a faster stint lap leaves it alone');
  });

  test(
    "a new round starts the delta afresh: last round's reference isn't used, and its first clean lap replaces it",
    () {
      final calc = SectorCalculator(persist: (_) async {})..round = 'Round 3 - Mount Panorama';
      final d = _Driver(calc, speedAt: (_) => 44)..drive(2);
      final fast = d.states.last.referenceLapMs!;

      calc.round = 'Round 3'; // renamed, same round: kept
      d.speedAt = (_) => 40;
      d.drive(1);
      expect(d.states.last.referenceLapMs, fast);

      calc.round = 'Round 4 - Alsace Village (Reverse)';
      final from = d.states.length;
      d.drive(1);
      expect(d.states.sublist(from, d.states.length - 1).map((s) => s.liveDeltaMs).whereType<int>(), isEmpty);
      expect(
        d.states.last.referenceLapMs,
        d.lastLapMs,
        reason: 'slower than last round, but it is this round\'s first',
      );
      expect(d.states.last.referenceLapMs, greaterThan(fast));
    },
  );
}
