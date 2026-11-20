/// The tyre a weather slot calls for.
enum WeatherTyre {
  slicks('Racing (slicks)'),
  inters('Intermediate'),
  wets('Heavy Wet');

  final String label;
  const WeatherTyre(this.label);
}

/// One GT7 weather slot from a league briefing, e.g. "R06": the letter
/// is the weather (R = rain, C = cloudy, S = sunny) and the number is
/// GT7's preset of it. For rain, higher is heavier (R01 light drizzle
/// to R08 torrential).
class WeatherSlot {
  final String code;
  const WeatherSlot(this.code);

  String get letter => code[0];
  int get number => int.parse(code.substring(1));
  bool get isRain => letter == 'R';

  static const _rainPresets = {
    1: 'Light Drizzle',
    2: 'Cloudless with Warm Rain',
    3: 'Light Rain',
    4: 'Cloudy with Rain',
    5: 'Cloudy with Rain II',
    6: 'Thick Cloud with Rain',
    7: 'Cloudy with Torrential Rain',
    8: 'Thick Cloud with Torrential Rain',
  };

  /// GT7's name for the preset, e.g. "Light Rain"; for cloudy and sunny
  /// slots just "Cloudy" / "Sunny".
  String get name => switch (letter) {
    'R' => _rainPresets[number] ?? 'Rain',
    'C' => 'Cloudy',
    _ => 'Sunny',
  };

  /// The tyre this slot's weather calls for, from community testing
  /// (GTPlanet): R01-R02 leave the track dry enough for slicks, R03 is
  /// the lightest that needs Intermediates, R06-R08 need full wets.
  WeatherTyre get tyre {
    if (!isRain || number <= 2) return WeatherTyre.slicks;
    return number >= 6 ? WeatherTyre.wets : WeatherTyre.inters;
  }
}

/// A run of consecutive slots calling for the same tyre, as slot
/// numbers counted from 1.
class WeatherPhase {
  final WeatherTyre tyre;
  final int firstSlot;
  final int lastSlot;
  const WeatherPhase(this.tyre, this.firstSlot, this.lastSlot);
}

/// The race's weather from the briefing, e.g. "R06/R05/C03/S14/S04/R03/
/// R04/R05": GT7 runs the slots in order over the race. Here they're
/// taken as spread evenly over the race distance, which gives the laps
/// each slot roughly covers -- an estimate. The in-game radar is the
/// truth: GT7 moves rain cells across the map, so light rain (R01-R03)
/// can miss the circuit or pass quickly; and the track stays wet for a
/// while after rain stops (and takes a while to soak once it starts),
/// so the surface lags the forecast.
class WeatherForecast {
  final List<WeatherSlot> slots;
  const WeatherForecast(this.slots);

  static final _slot = RegExp(r'^[RCS]\d{1,2}$');

  /// Parses slot codes separated by "/", commas or spaces (case doesn't
  /// matter; "R6" reads as "R06"). Null if empty or any code isn't one.
  static WeatherForecast? tryParse(String text) {
    final tokens = text.toUpperCase().split(RegExp(r'[\s/,]+')).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty || !tokens.every(_slot.hasMatch)) return null;
    return WeatherForecast([for (final t in tokens) WeatherSlot('${t[0]}${t.substring(1).padLeft(2, '0')}')]);
  }

  /// As entered in the briefing: "R06/R05/...".
  String get code => slots.map((s) => s.code).join('/');

  bool get hasRain => slots.any((s) => s.isRain);

  /// Rain heavy enough for Inters or Wets somewhere in the race (light
  /// rain, R01-R02, is still a slick race).
  bool get needsWetTyres => slots.any((s) => s.isRain && s.tyre != WeatherTyre.slicks);

  /// The race split by the tyre the weather calls for.
  List<WeatherPhase> get phases {
    final result = <WeatherPhase>[];
    for (var i = 0; i < slots.length; i++) {
      final tyre = slots[i].tyre;
      if (result.isNotEmpty && result.last.tyre == tyre) {
        result[result.length - 1] = WeatherPhase(tyre, result.last.firstSlot, i + 1);
      } else {
        result.add(WeatherPhase(tyre, i + 1, i + 1));
      }
    }
    return result;
  }

  /// "Heavy Wet → Intermediate → Racing (slicks) → Intermediate".
  String get summary => phases.map((p) => p.tyre.label).join(' → ');

  /// The laps slot [slot] (from 1) roughly covers in a [totalLaps] race.
  (int, int) lapsOfSlot(int slot, int totalLaps) => _laps(slot, slot, totalLaps);

  /// The laps [phase] roughly covers in a [totalLaps] race.
  (int, int) lapsOfPhase(WeatherPhase phase, int totalLaps) => _laps(phase.firstSlot, phase.lastSlot, totalLaps);

  (int, int) _laps(int first, int last, int totalLaps) {
    // Fewer laps than slots (or none set yet) still gives a lap range,
    // never an error: each slot gets at least its lap, within the race.
    final laps = totalLaps < 1 ? 1 : totalLaps;
    final perSlot = laps / slots.length;
    final from = (((first - 1) * perSlot).round() + 1).clamp(1, laps);
    final to = (last * perSlot).round().clamp(from, laps);
    return (from, to);
  }

  /// The slot (from 1) lap [lap] of [totalLaps] falls in.
  /// (Matches [lapsOfSlot], so a lap is always in the slot it's listed under.)
  int slotAtLap(int lap, int totalLaps) {
    for (var slot = 1; slot < slots.length; slot++) {
      if (lap <= lapsOfSlot(slot, totalLaps).$2) return slot;
    }
    return slots.length;
  }

  /// For Boxington: the slots, the rain/dry phases with their rough
  /// laps, and -- during a race -- where we are in it now.
  Map<String, dynamic> toPromptContext({int? totalLaps, int? currentLap}) {
    final laps = totalLaps != null && totalLaps > 0 ? totalLaps : null;
    String lapRange((int, int) r) => r.$1 == r.$2 ? 'lap ${r.$1}' : 'laps ${r.$1}-${r.$2}';
    final now = laps != null && currentLap != null && currentLap > 0 ? slotAtLap(currentLap, laps) : null;
    return {
      'slots': code,
      'phases': [
        for (final p in phases)
          '${p.tyre.label} (slot${p.firstSlot == p.lastSlot ? ' ${p.firstSlot}' : 's ${p.firstSlot}-${p.lastSlot}'}'
              '${laps == null ? '' : ', about ${lapRange(lapsOfPhase(p, laps))}'})',
      ],
      'slotWeather': [for (final s in slots) '${s.code} ${s.name} -> ${s.tyre.label}'],
      if (now != null) 'currentSlot': '$now of ${slots.length} (${slots[now - 1].code} ${slots[now - 1].name})',
      if (now != null && now < slots.length) 'nextSlot': '${slots[now].code} ${slots[now].name} from about lap ${lapsOfSlot(now + 1, laps!).$1}',
    };
  }
}
