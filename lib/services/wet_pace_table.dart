import '../models/practice_lap_record.dart';
import '../models/weather_forecast.dart';
import 'stint_summary.dart';

/// A tyre's measured pace in one weather: the typical lap (median of
/// the counted laps) of the latest practice stint on it in that weather.
class WetPace {
  final String compound;
  final double lapMs;
  final int laps;
  final int stintNumber;
  const WetPace(this.compound, this.lapMs, this.laps, this.stintNumber);
}

/// Two tyres compared in one weather: how much faster [faster] is a
/// lap, and so how many laps it takes to win back a pit stop.
class WetSwitch {
  final String level;
  final WeatherTyre faster;
  final WeatherTyre slower;
  final double deltaMs;
  const WetSwitch(this.level, this.faster, this.slower, this.deltaMs);

  /// Laps on the faster tyre to make up [pitLossSeconds].
  double lapsToPayBack(double pitLossSeconds) => deltaMs <= 0 ? double.infinity : pitLossSeconds * 1000 / deltaMs;
}

/// Wet-weather testing: each tyre's pace at each GT7 weather (dry and
/// the rain presets R01-R08), from practice stints tagged with the
/// weather the driver set (see PracticeLapLogger.setWeather). Answers
/// whether a tyre change pays: a faster tyre has to win back the pit
/// stop over the laps it's used.
///
/// Slick compounds are taken together as "slicks" (the quickest one
/// tested counts).
class WetPaceTable {
  /// A stint needs this many counted laps to give a pace.
  static const int minLaps = 3;

  /// A stint left tagged dry whose water gauge read this much or more
  /// was really wet (the WEATHER chip not set) -- it's left out rather
  /// than filed as dry pace. The water model still uses its laps.
  static const double wetTrackPercent = 10;

  /// Every weather, in order of how wet.
  static const levels = ['DRY', 'R01', 'R02', 'R03', 'R04', 'R05', 'R06', 'R07', 'R08'];

  final Map<(String, WeatherTyre), WetPace> _cells;
  WetPaceTable._(this._cells);

  factory WetPaceTable.fromLaps(List<PracticeLapRecord> laps) {
    // Latest stint per (weather, compound); StintSummary lists newest first.
    final latest = <(String, String), WetPace>{};
    for (final stint in StintSummary.fromLaps(laps)) {
      if (stint.stintNumber == 0 || stint.isRace || stint.lapCount < minLaps) continue;
      if (stint.weatherLevel == 'DRY' && stint.laps.any((l) => (l.waterPercent ?? 0) >= wetTrackPercent)) continue;
      final pace = stint.typicalLapMs;
      if (pace == null) continue;
      latest.putIfAbsent(
        (stint.weatherLevel, stint.tyreCompound),
        () => WetPace(stint.tyreCompound, pace, stint.lapCount, stint.stintNumber),
      );
    }
    final cells = <(String, WeatherTyre), WetPace>{};
    for (final MapEntry(key: (level, compound), value: pace) in latest.entries) {
      final key = (level, tyreOf(compound));
      final existing = cells[key];
      if (existing == null || pace.lapMs < existing.lapMs) cells[key] = pace;
    }
    return WetPaceTable._(cells);
  }

  static WeatherTyre tyreOf(String compound) => switch (compound) {
    'Intermediate' => WeatherTyre.inters,
    'Heavy Wet' => WeatherTyre.wets,
    _ => WeatherTyre.slicks,
  };

  /// The weather a forecast slot is tested as: its rain preset, or DRY
  /// for cloudy and sunny.
  static String levelOf(WeatherSlot slot) => slot.isRain ? slot.code : 'DRY';

  /// The two tyres worth comparing in [level]: around the crossover the
  /// community testing puts there (R01-R03 slicks against inters, R04
  /// and wetter inters against wets).
  static (WeatherTyre, WeatherTyre) candidates(String level) {
    final n = level == 'DRY' ? 0 : int.parse(level.substring(1));
    return n <= 3 ? (WeatherTyre.slicks, WeatherTyre.inters) : (WeatherTyre.inters, WeatherTyre.wets);
  }

  WetPace? pace(String level, WeatherTyre tyre) => _cells[(level, tyre)];

  bool get isEmpty => _cells.isEmpty;

  /// Every weather with a measured pace.
  Iterable<String> get testedLevels => levels.where((l) => WeatherTyre.values.any((t) => _cells.containsKey((l, t))));

  /// The weathers to show: those in [forecast] plus any already tested,
  /// in order of how wet.
  List<String> levelsFor(WeatherForecast? forecast) {
    final wanted = {...?forecast?.slots.map(levelOf), ...testedLevels};
    return levels.where(wanted.contains).toList();
  }

  /// The runs still to do for [forecast]: both candidate tyres in each
  /// of its weathers, wettest first (they're the ones that decide a
  /// race-start tyre).
  List<(String, WeatherTyre)> toTest(WeatherForecast forecast) => [
    for (final level in levelsFor(forecast).reversed)
      if (forecast.slots.any((s) => levelOf(s) == level))
        for (final tyre in [candidates(level).$1, candidates(level).$2])
          if (pace(level, tyre) == null) (level, tyre),
  ];

  /// The two candidates compared in [level], once both are tested.
  WetSwitch? compare(String level) {
    final (a, b) = candidates(level);
    final pa = pace(level, a), pb = pace(level, b);
    if (pa == null || pb == null) return null;
    return pa.lapMs <= pb.lapMs ? WetSwitch(level, a, b, pb.lapMs - pa.lapMs) : WetSwitch(level, b, a, pa.lapMs - pb.lapMs);
  }

  /// For Boxington: each tested weather's paces and what a switch is
  /// worth against a [pitLossSeconds] stop.
  List<String> toPromptContext({required double pitLossSeconds}) => [
    for (final level in testedLevels)
      [
        '$level:',
        for (final t in WeatherTyre.values)
          if (pace(level, t) case final p?) '${t.label} ${_format(p.lapMs)}',
        if (compare(level) case final c?)
          '-> ${c.faster.label} ${(c.deltaMs / 1000).toStringAsFixed(1)}s/lap faster, '
              'pays back a ${pitLossSeconds.round()}s stop in ${c.lapsToPayBack(pitLossSeconds).ceil()} laps',
      ].join(' '),
  ];

  static String _format(double ms) {
    final minutes = ms ~/ 60000;
    return '$minutes:${((ms % 60000) / 1000).toStringAsFixed(3).padLeft(6, '0')}';
  }
}
