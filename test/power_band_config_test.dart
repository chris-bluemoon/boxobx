import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/power_band_config.dart';

void main() {
  test('the BMW M6 GT3 Endurance car ID maps to its hand-tuned window', () {
    expect(PowerBandConfig.forCar(3218, minAlertRpm: 5000, maxAlertRpm: 7500), PowerBandConfig.bmwM6Gt3Endurance);
  });

  test('an unknown car derives its window from the rev-indicator range', () {
    final config = PowerBandConfig.forCar(9999, minAlertRpm: 7000, maxAlertRpm: 8000);
    expect(config.optimalShiftRpm, 7500);
    expect(config.overRevRpm, 8000);
  });

  test('falls back to the BMW config when there is no usable car data', () {
    expect(PowerBandConfig.forCar(0), PowerBandConfig.bmwM6Gt3Endurance);
    expect(PowerBandConfig.forCar(9999, minAlertRpm: 8000, maxAlertRpm: 7000), PowerBandConfig.bmwM6Gt3Endurance);
  });
}
