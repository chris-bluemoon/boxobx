import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/hud_overlay_data.dart';

void main() {
  group('HudOverlayData.fromMap tire wear/compound fields', () {
    test('parses all 4 tire-wear percents and compound when present', () {
      final data = HudOverlayData.fromMap({
        'gridPosition': 9,
        'tireWearFrontLeftPercent': 54.05,
        'tireWearFrontRightPercent': 59.46,
        'tireWearRearLeftPercent': 61.11,
        'tireWearRearRightPercent': 66.67,
        'tireCompound': 'RS',
      });

      expect(data.tireWearFrontLeftPercent, 54.05);
      expect(data.tireWearFrontRightPercent, 59.46);
      expect(data.tireWearRearLeftPercent, 61.11);
      expect(data.tireWearRearRightPercent, 66.67);
      expect(data.tireCompound, 'RS');
    });

    test('defaults all tire-wear/compound fields to null when absent', () {
      final data = HudOverlayData.fromMap({'gridPosition': 9});

      expect(data.tireWearFrontLeftPercent, isNull);
      expect(data.tireWearFrontRightPercent, isNull);
      expect(data.tireWearRearLeftPercent, isNull);
      expect(data.tireWearRearRightPercent, isNull);
      expect(data.tireCompound, isNull);
    });

    test('HudOverlayData.empty() has null tire-wear/compound fields', () {
      final data = HudOverlayData.empty();

      expect(data.tireWearFrontLeftPercent, isNull);
      expect(data.tireCompound, isNull);
    });
  });

  group('HudOverlayData.fromMap standings', () {
    test('parses every visible leaderboard row', () {
      final data = HudOverlayData.fromMap({
        'gridPosition': 9,
        'standings': [
          {'name': 'Chuck_E82', 'position': 8, 'gapToAhead': null, 'inPit': true, 'isPlayer': false},
          {'name': 'Willy-SwerveX', 'position': 9, 'gapToAhead': 1.4, 'inPit': false, 'isPlayer': true},
        ],
      });
      expect(data.standings, hasLength(2));
      expect(data.standings[0].name, 'Chuck_E82');
      expect(data.standings[0].inPit, isTrue);
      expect(data.standings[0].gapToAhead, isNull);
      expect(data.standings[1].position, 9);
      expect(data.standings[1].gapToAhead, 1.4);
      expect(data.standings[1].isPlayer, isTrue);
    });

    test('defaults to no rows when absent', () {
      expect(HudOverlayData.fromMap({'gridPosition': 9}).standings, isEmpty);
      expect(HudOverlayData.empty().standings, isEmpty);
    });
  });
}
