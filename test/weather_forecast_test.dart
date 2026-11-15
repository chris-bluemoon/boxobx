import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/models/weather_forecast.dart';

void main() {
  const brief = 'R06/R05/C03/S14/S04/R03/R04/R05';

  test('reads the briefing code into rain and dry spells', () {
    final f = WeatherForecast.tryParse(brief)!;
    expect(f.slots, hasLength(8));
    expect(f.code, brief);
    expect(f.summary, 'Heavy Wet → Intermediate → Racing (slicks) → Intermediate');
    expect([for (final p in f.phases) (p.tyre, p.firstSlot, p.lastSlot)], [
      (WeatherTyre.wets, 1, 1),
      (WeatherTyre.inters, 2, 2),
      (WeatherTyre.slicks, 3, 5),
      (WeatherTyre.inters, 6, 8),
    ]);
  });

  test('rain presets: names, and the tyre each calls for', () {
    final f = WeatherForecast.tryParse('R01/R02/R03/R05/R06/R08/C03/S14')!;
    expect(f.slots.map((s) => s.name), [
      'Light Drizzle', 'Cloudless with Warm Rain', 'Light Rain', 'Cloudy with Rain II',
      'Thick Cloud with Rain', 'Thick Cloud with Torrential Rain', 'Cloudy', 'Sunny',
    ]);
    expect(f.slots.map((s) => s.tyre), [
      WeatherTyre.slicks, WeatherTyre.slicks, WeatherTyre.inters, WeatherTyre.inters,
      WeatherTyre.wets, WeatherTyre.wets, WeatherTyre.slicks, WeatherTyre.slicks,
    ]);
  });

  test('loose typing is accepted; anything else is not', () {
    expect(WeatherForecast.tryParse(' r6, r05 c3 ')!.code, 'R06/R05/C03');
    expect(WeatherForecast.tryParse(''), isNull);
    expect(WeatherForecast.tryParse('R06/X05'), isNull);
    expect(WeatherForecast.tryParse('R/C03'), isNull);
  });

  test('each spell covers its share of the race laps', () {
    final f = WeatherForecast.tryParse(brief)!;
    final phases = f.phases;
    expect([for (final p in phases) f.lapsOfPhase(p, 24)], [(1, 3), (4, 6), (7, 15), (16, 24)]);
    expect(f.slotAtLap(1, 24), 1);
    expect(f.slotAtLap(7, 24), 3);
    expect(f.slotAtLap(24, 24), 8);
    // Ranges never overlap, and agree with slotAtLap.
    expect([for (final p in phases) f.lapsOfPhase(p, 26)], [(1, 3), (4, 7), (8, 16), (17, 26)]);
    expect([f.slotAtLap(7, 26), f.slotAtLap(8, 26)], [2, 3]);
  });

  test('Boxington sees the spells and, in a race, where we are', () {
    final f = WeatherForecast.tryParse(brief)!;
    final ctx = f.toPromptContext(totalLaps: 24, currentLap: 5);
    expect(ctx['phases'], [
      'Heavy Wet (slot 1, about laps 1-3)',
      'Intermediate (slot 2, about laps 4-6)',
      'Racing (slicks) (slots 3-5, about laps 7-15)',
      'Intermediate (slots 6-8, about laps 16-24)',
    ]);
    expect((ctx['slotWeather'] as List).first, 'R06 Thick Cloud with Rain -> Heavy Wet');
    expect(ctx['currentSlot'], '2 of 8 (R05 Cloudy with Rain II)');
    expect(ctx['nextSlot'], 'C03 Cloudy from about lap 7');
    expect(f.toPromptContext().containsKey('currentSlot'), isFalse);
  });

  test('the briefing saves its weather slots', () {
    final b = RaceBriefing.fromMap(
      const RaceBriefing(trackName: 'Nürburgring Sprint', totalLaps: 24, startingFuelPercent: 100, availableTireCompounds: ['Racing Medium'], weatherSlots: brief).toMap(),
    );
    expect(b.weather!.code, brief);
    expect(const RaceBriefing(trackName: 'X', totalLaps: 1, startingFuelPercent: 100, availableTireCompounds: []).weather, isNull);
  });
}
