import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/hud_overlay_data.dart';
import 'package:boxbox/models/opponent_pit_stop.dart';
import 'package:boxbox/services/pit_lane_monitor.dart';

void main() {
  const noService = PitLaneEntry(position: 2);
  const softs = PitLaneEntry(position: 2, tyre: 'S', fuel: 20);

  test('announces as soon as the tyre being fitted is known', () {
    final monitor = PitLaneMonitor();
    final announced = monitor.check({'Daywalkar86': softs}, ourLap: 7);
    expect(announced.single.driver, 'Daywalkar86');
    expect(announced.single.tyre, 'S');
    expect(announced.single.ourLap, 7);
  });

  test('waits for the tyre, then announces after 3 readings without one', () {
    final monitor = PitLaneMonitor();
    expect(monitor.check({'Daywalkar86': noService}, ourLap: 7), isEmpty);
    expect(monitor.check({'Daywalkar86': noService}, ourLap: 7), isEmpty);
    final announced = monitor.check({'Daywalkar86': noService}, ourLap: 7);
    expect(announced.single.tyre, isNull);
  });

  test('announces once per stop, and keeps the log updated with tyre and the highest fuel', () {
    final monitor = PitLaneMonitor();
    monitor.check({'Daywalkar86': noService}, ourLap: 7);
    expect(monitor.check({'Daywalkar86': softs}, ourLap: 7), hasLength(1));
    expect(monitor.check({'Daywalkar86': const PitLaneEntry(position: 2, tyre: 'S', fuel: 57)}, ourLap: 7), isEmpty);
    expect(monitor.check({'Daywalkar86': const PitLaneEntry(position: 2, tyre: 'S', fuel: 31)}, ourLap: 7), isEmpty);

    final stop = monitor.stops.single;
    expect(stop.tyre, 'S');
    expect(stop.fuel, 57);
    expect(stop.toPromptContext(), {
      'driver': 'Daywalkar86',
      'position': 2,
      'ourLap': 7,
      'tyre': 'softs',
      'fuelAdded': 57,
    });
  });

  test('an OCR flicker during one stop does not log a second stop', () {
    final monitor = PitLaneMonitor();
    monitor.check({'Daywalkar86': softs}, ourLap: 7);
    monitor.check({}, ourLap: 7);
    monitor.check({}, ourLap: 7);
    expect(monitor.check({'Daywalkar86': softs}, ourLap: 7), isEmpty);
    expect(monitor.stops, hasLength(1));
  });

  test('a genuine second stop later is logged and announced again', () {
    final monitor = PitLaneMonitor();
    monitor.check({'Daywalkar86': softs}, ourLap: 7);
    for (var i = 0; i < 5; i++) {
      monitor.check({}, ourLap: 8);
    }
    final second = monitor.check({'Daywalkar86': const PitLaneEntry(position: 4, tyre: 'M')}, ourLap: 18);
    expect(second.single.ourLap, 18);
    expect(monitor.stops.map((s) => s.tyre), ['S', 'M']);
  });

  test('a driver who leaves before being announced is still announced once', () {
    final monitor = PitLaneMonitor();
    monitor.check({'Daywalkar86': noService}, ourLap: 7);
    var announced = <OpponentPitStop>[];
    for (var i = 0; i < 5; i++) {
      announced = monitor.check({}, ourLap: 7);
    }
    expect(announced.single.driver, 'Daywalkar86');
  });

  test('reset clears the log', () {
    final monitor = PitLaneMonitor()..check({'Daywalkar86': softs}, ourLap: 7);
    monitor.reset();
    expect(monitor.stops, isEmpty);
  });

  test('HudOverlayData parses the relay object format and the older bare-position format', () {
    final hud = HudOverlayData.fromMap({
      'driversInPit': {
        'Daywalkar86': {'position': 2, 'tyre': 'S', 'fuel': 57},
        'LocoRx2': 0,
      },
    });
    expect(hud.driversInPit['Daywalkar86']!.tyre, 'S');
    expect(hud.driversInPit['Daywalkar86']!.fuel, 57);
    expect(hud.driversInPit['LocoRx2']!.position, isNull);
    expect(HudOverlayData.fromMap({}).driversInPit, isEmpty);
  });

  test('every GT7 compound letter has a spoken name', () {
    expect(['S', 'M', 'H', 'IM', 'W'].map(OpponentPitStop.tyreName), ['softs', 'mediums', 'hards', 'inters', 'wets']);
  });
}
