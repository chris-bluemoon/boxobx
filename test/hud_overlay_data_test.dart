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

  group('HudOverlayData.fromMap rivalPositions', () {
    test('parses a non-empty rivalPositions map', () {
      final data = HudOverlayData.fromMap({
        'gridPosition': 9,
        'rivalPositions': {'Chuck_E82': 4, 'Willy-SwerveX': 7},
      });

      expect(data.rivalPositions, {'Chuck_E82': 4, 'Willy-SwerveX': 7});
    });

    test('defaults to an empty map when absent', () {
      final data = HudOverlayData.fromMap({'gridPosition': 9});
      expect(data.rivalPositions, isEmpty);
    });

    test('HudOverlayData.empty() has an empty rivalPositions map', () {
      expect(HudOverlayData.empty().rivalPositions, isEmpty);
    });
  });
}
