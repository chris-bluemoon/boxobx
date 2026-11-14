import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/hud_overlay_data.dart';
import 'package:boxbox/models/traffic_map.dart';

void main() {
  final relayPayload = {
    'trackReady': true,
    'playerLapProgress': 412.5,
    'lapSeconds': 100.0,
    'cars': [
      {'lapProgress': 400.0, 'count': 1, 'secondsBehind': 1.5},
      {'lapProgress': 380.0, 'count': 2, 'secondsBehind': 2.8},
      {'lapProgress': 420.0, 'count': 1, 'secondsBehind': 98.0}, // 2s ahead
      {'lapProgress': 100.0, 'count': 1, 'secondsBehind': 40.0},
      {'lapProgress': 150.0, 'count': 1, 'secondsBehind': null},
    ],
  };

  test('parses the relay traffic payload', () {
    final traffic = HudOverlayData.fromMap({'traffic': relayPayload}).traffic;
    expect(traffic.trackReady, isTrue);
    expect(traffic.playerLapProgress, 412.5);
    expect(traffic.cars, hasLength(5));
    expect(traffic.cars[1].count, 2);
    expect(HudOverlayData.fromMap({}).traffic.trackReady, isFalse);
  });

  test('relative seconds are positive behind and negative ahead, the short way round', () {
    final traffic = TrafficMap.fromJson(relayPayload);
    expect(traffic.relativeSeconds(traffic.cars[0]), 1.5);
    expect(traffic.relativeSeconds(traffic.cars[2]), -2.0);
    expect(traffic.relativeSeconds(traffic.cars[3]), 40.0);
    expect(traffic.relativeSeconds(traffic.cars[4]), isNull);
  });

  test('the prompt summary counts bunched cars and lists the nearest by gap', () {
    final summary = TrafficMap.fromJson(relayPayload).toPromptContext()!;
    expect(summary['carsWithin3sBehind'], 3); // 1 + a bunch of 2
    expect(summary['carsWithin3sAhead'], 1);
    expect(summary['nearestCars'], [
      {'seconds': 1.5},
      {'seconds': -2.0},
      {'seconds': 2.8, 'count': 2},
      {'seconds': 40.0},
    ]);
  });

  test('no prompt summary before the track is learned or timed', () {
    expect(TrafficMap.empty.toPromptContext(), isNull);
    expect(const TrafficMap(trackReady: true).toPromptContext(), isNull);
  });
}
