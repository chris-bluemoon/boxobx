import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/hud_overlay_data.dart';
import 'package:boxbox/models/weather_forecast.dart';
import 'package:boxbox/models/weather_radar.dart';
import 'package:boxbox/services/water_trend.dart';
import 'package:boxbox/services/wet_tyre_caller.dart';

void main() {
  group('water trend', () {
    WaterTrend falling(double perMinute, {int readings = 30, double from = 49}) {
      final trend = WaterTrend();
      final t0 = DateTime(2026, 11, 15, 13);
      for (var i = 0; i < readings; i++) {
        trend.add(from + perMinute * i * 3 / 60, t0.add(Duration(seconds: i * 3)));
      }
      return trend;
    }

    test('the drying rate from the gauge, as measured at the Nurburgring', () {
      final trend = falling(-3);
      expect(trend.percentPerMinute, closeTo(-3, 0.01));
      // 49% now (last reading ~44.6): reaching 33% takes ~3.9 minutes.
      expect(trend.secondsTo(33.3, 44.65), closeTo(227, 2));
      expect(trend.secondsTo(60, 44.65), isNull, reason: 'not heading that way');
    });

    test('too few readings, or too short a span: no trend', () {
      expect(falling(-3, readings: 4).percentPerMinute, isNull);
      expect(falling(-3, readings: 8).percentPerMinute, isNull, reason: '21 s span');
      expect(falling(0.1).secondsTo(33, 49), isNull, reason: 'steady');
    });

    test('only the last 90 seconds count', () {
      final trend = WaterTrend();
      final t0 = DateTime(2026, 11, 15, 13);
      for (var i = 0; i < 40; i++) {
        trend.add(50, t0.add(Duration(seconds: i * 3))); // flat for 2 minutes
      }
      for (var i = 40; i < 80; i++) {
        trend.add(50 + (i - 40) * 0.3, t0.add(Duration(seconds: i * 3))); // then rising 6%/min
      }
      expect(trend.percentPerMinute, closeTo(6, 0.3));
    });
  });

  test('the relay\'s radar reading reaches the HUD data', () {
    final hud = HudOverlayData.fromMap({
      'radar': {'overTrack': false, 'nearestRainKm': 47.4, 'arrivalSeconds': 67.1, 'driftKmPerMin': 53.7, 'trend': 'steady'},
    });
    expect(hud.radar!.nearestRainKm, 47.4);
    expect(hud.radar!.describe(), 'nearest rain 47 km out, arriving in about 67 s');
    expect(HudOverlayData.fromMap({}).radar, isNull);
    expect(const WeatherRadar(overTrack: true, trend: 'fading').describe(), 'rain over the track, fading');
  });

  group('Boxington with the trend and the radar', () {
    final brief = WeatherForecast.tryParse('R06/R05/C03/S14/S04/R03/R04/R05')!;
    String? check(
      WetTyreCaller caller, {
      required int lap,
      required double water,
      required String tyre,
      double? perMinute,
      WeatherRadar? radar,
    }) => caller.check(
      forecast: brief,
      currentLap: lap,
      totalLaps: 26,
      currentCompound: tyre,
      laps: const [],
      pitLossSeconds: 30,
      waterPercent: water,
      waterPercentPerMinute: perMinute,
      lapSeconds: 100,
      radar: radar,
    );

    test('box a lap early when the trend crosses the line before a stop is done', () {
      // 38% and falling 6%/min (10% a lap): about 28% once out of the pits.
      final call = check(WetTyreCaller(), lap: 9, water: 38, tyre: 'Intermediate', perMinute: -6)!;
      expect(call, contains('water gauge trend: 38% water now'));
      expect(call, contains('about 28% by the time a stop this lap is done'));
      expect(call, contains('Racing (slicks)'));
      // Steady at 38%: nothing to call yet.
      expect(check(WetTyreCaller(), lap: 9, water: 38, tyre: 'Intermediate', perMinute: 0.1), isNull);
    });

    test('no slicks call when the water is already rising back over the line', () {
      // 30% (slicks territory) but rising 6%/min: 40% by the time a stop's done.
      expect(check(WetTyreCaller(), lap: 9, water: 30, tyre: 'Intermediate', perMinute: 6), isNull);
    });

    test('drying: a heads-up a couple of laps before the line', () {
      final caller = WetTyreCaller();
      // 50%, falling 10% a lap: the 33% line in about 1.7 laps.
      final call = check(caller, lap: 9, water: 50, tyre: 'Intermediate', perMinute: -6, radar: const WeatherRadar())!;
      expect(call, contains("radar's clear over the track"));
      expect(call, contains('in about 1.7 laps'));
      expect(call, contains('not to box yet'));
      expect(check(caller, lap: 10, water: 45, tyre: 'Intermediate', perMinute: -6, radar: const WeatherRadar()), isNull);
    });

    test('rain on the radar heading for the track while on slicks', () {
      final caller = WetTyreCaller();
      const coming = WeatherRadar(nearestRainKm: 47, arrivalSeconds: 150, trend: 'steady');
      final call = check(caller, lap: 11, water: 5, tyre: 'Racing Medium', radar: coming)!;
      expect(call, contains('rain 47 km out, reaching the track in about 1.5 laps'));
      expect(call, contains('no pit call yet'));
      expect(check(caller, lap: 12, water: 5, tyre: 'Racing Medium', radar: coming), isNull, reason: 'warned once');
      // The radar clears, then new rain: a new warning.
      check(caller, lap: 13, water: 5, tyre: 'Racing Medium', radar: const WeatherRadar());
      expect(check(caller, lap: 14, water: 5, tyre: 'Racing Medium', radar: coming), isNotNull);
    });

    test('rain over the track before the gauge has caught up', () {
      final call = check(
        WetTyreCaller(),
        lap: 11,
        water: 8,
        tyre: 'Racing Medium',
        radar: const WeatherRadar(overTrack: true, coverageAtTrackPercent: 90, trend: 'building'),
      )!;
      expect(call, contains('rain over the track now, building'));
    });

    test('far-off rain, or rain heading away, says nothing', () {
      const away = WeatherRadar(nearestRainKm: 60);
      expect(check(WetTyreCaller(), lap: 11, water: 5, tyre: 'Racing Medium', radar: away), isNull);
      const slow = WeatherRadar(nearestRainKm: 90, arrivalSeconds: 900);
      expect(check(WetTyreCaller(), lap: 11, water: 5, tyre: 'Racing Medium', radar: slow), isNull);
    });
  });
}
