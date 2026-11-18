import '../models/practice_lap_record.dart';
import 'practice_log_store.dart';
import 'race_report.dart';

/// One round's laps, for the driver profile.
class ProfileRound {
  final String round;
  final String track;
  final List<PracticeLapRecord> laps;

  const ProfileRound({required this.round, required this.track, required this.laps});
}

/// Wet or dry driving, summed over every round.
class ConditionStats {
  final int laps;

  /// Laps with spins tracked (logged since spin detection), and the spins on them.
  final int spinTrackedLaps;
  final int spins;
  final double? lockupPercent;
  final double? wheelspinPercent;

  const ConditionStats({
    this.laps = 0,
    this.spinTrackedLaps = 0,
    this.spins = 0,
    this.lockupPercent,
    this.wheelspinPercent,
  });

  double? get spinsPer10Laps => spinTrackedLaps < 5 ? null : spins * 10 / spinTrackedLaps;
}

/// One race, for the diary.
class RaceDiaryEntry {
  final DateTime date;
  final String track;
  final String conditions; // 'dry', 'wet' or 'mixed'
  final int laps;
  final int? positionAfterLap1;
  final int? finishingPosition;
  final int stops;
  final int? spins; // null: not tracked
  final List<int> spinCorners;
  final int? bestLapMs;

  const RaceDiaryEntry({
    required this.date,
    required this.track,
    required this.conditions,
    required this.laps,
    this.positionAfterLap1,
    this.finishingPosition,
    required this.stops,
    this.spins,
    this.spinCorners = const [],
    this.bestLapMs,
  });

  /// Places gained from the end of lap 1 to the flag (negative = lost).
  int? get placesGained =>
      positionAfterLap1 == null || finishingPosition == null ? null : positionAfterLap1! - finishingPosition!;

  String describe() {
    final d = '${date.day} ${_months[date.month - 1]}';
    final result = finishingPosition == null
        ? ''
        : positionAfterLap1 == null
        ? ', finished P$finishingPosition'
        : ', P$positionAfterLap1 after lap 1, finished P$finishingPosition';
    final spun = spins == null
        ? ''
        : spins == 0
        ? ', no spins'
        : ', $spins spin${spins == 1 ? '' : 's'}${_cornerList(spinCorners)}';
    final best = bestLapMs == null ? '' : ', best lap ${_lapTime(bestLapMs!)}';
    return '$d, $track, $conditions: $laps laps$result, $stops stop${stops == 1 ? '' : 's'}$spun$best.';
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
}

/// What Boxington knows about the driver, from every lap logged in every
/// round: how they go in the wet against the dry (spins, lock-ups,
/// wheelspin, pace on the same track), where they win and lose places,
/// the corners that keep catching them out, and a diary of recent races.
/// Worked out afresh from the laps, so it grows over the season and a
/// deleted race drops out of it.
class DriverProfile {
  /// Whether the profile goes in Boxington's prompt and spins are called
  /// out -- both cost Groq tokens/requests, so this is the switch if the
  /// rate limits bite. Off, spins are still logged and the profile still
  /// builds and shows on Race Reports.
  static const bool boxingtonUsesIt = true;

  final ConditionStats dry;
  final ConditionStats wet;

  /// Wet laps against dry laps on the same track: (track, percent slower).
  final List<(String, double)> wetPaceLoss;

  /// Places gained from the end of lap 1 to the flag, averaged, by race
  /// conditions -- null where there are no such races.
  final double? dryRacePlaces;
  final double? wetRacePlaces;
  final int dryRaces;
  final int wetRaces;

  /// (track, corner, spins) where spins have happened more than once.
  final List<(String, int, int)> spinHotspots;

  /// Every race, newest first.
  final List<RaceDiaryEntry> diary;

  final int rounds;

  const DriverProfile({
    this.dry = const ConditionStats(),
    this.wet = const ConditionStats(),
    this.wetPaceLoss = const [],
    this.dryRacePlaces,
    this.wetRacePlaces,
    this.dryRaces = 0,
    this.wetRaces = 0,
    this.spinHotspots = const [],
    this.diary = const [],
    this.rounds = 0,
  });

  static const DriverProfile empty = DriverProfile();

  bool get isEmpty => dry.laps + wet.laps == 0;

  /// A lap in the wet: on wet tyres, the water gauge at the Inters line
  /// (33%) or more, or practice set to rain heavier than drizzle.
  static bool isWet(PracticeLapRecord lap) {
    if (lap.tireCompound == 'Intermediate' || lap.tireCompound == 'Heavy Wet') return true;
    if ((lap.waterPercent ?? 0) >= 33) return true;
    final weather = lap.weather;
    if (weather != null && weather.startsWith('R')) return (int.tryParse(weather.substring(1)) ?? 0) >= 3;
    return false;
  }

  static DriverProfile fromRounds(List<ProfileRound> rounds) {
    final dryLaps = <PracticeLapRecord>[];
    final wetLaps = <PracticeLapRecord>[];
    final paceLoss = <(String, double)>[];
    final hotspots = <(String, int), int>{};
    final diary = <RaceDiaryEntry>[];

    for (final round in rounds) {
      final clean = round.laps.where((l) => !l.isPitLap && l.lapTimeMs > 0).toList();
      final dry = clean.where((l) => !isWet(l)).toList();
      final wet = clean.where(isWet).toList();
      dryLaps.addAll(dry);
      wetLaps.addAll(wet);

      // Same track, both conditions: how much the wet costs.
      if (dry.length >= 3 && wet.length >= 3) {
        final d = _median([for (final l in dry) l.lapTimeMs.toDouble()]);
        final w = _median([for (final l in wet) l.lapTimeMs.toDouble()]);
        paceLoss.add((round.track, (w - d) / d * 100));
      }

      for (final lap in round.laps) {
        for (final corner in lap.spinCorners ?? const <int>[]) {
          if (corner > 0) hotspots[(round.track, corner)] = (hotspots[(round.track, corner)] ?? 0) + 1;
        }
      }

      for (final race in RaceReport.fromLaps(round.laps)) {
        if (race.lapCount < 3) continue; // a short run, not a race
        final wetShare = race.laps.where(isWet).length / race.lapCount;
        final tracked = race.laps.any((l) => l.spinCorners != null);
        diary.add(
          RaceDiaryEntry(
            date: race.startedAt,
            track: round.track,
            conditions: wetShare >= 0.6
                ? 'wet'
                : wetShare <= 0.2
                ? 'dry'
                : 'mixed',
            laps: race.lapCount,
            positionAfterLap1: race.laps.first.position,
            finishingPosition: race.finishingPosition,
            stops: race.pitStops.length,
            spins: tracked ? race.laps.fold<int>(0, (n, l) => n + l.spinCount) : null,
            spinCorners: [
              for (final l in race.laps)
                for (final c in l.spinCorners ?? const <int>[]) c,
            ],
            bestLapMs: race.bestLapMs,
          ),
        );
      }
    }
    diary.sort((a, b) => b.date.compareTo(a.date));

    double? placesIn(String conditions) {
      final gained = [
        for (final r in diary)
          if (r.conditions == conditions && r.placesGained != null) r.placesGained!,
      ];
      return gained.isEmpty ? null : gained.reduce((a, b) => a + b) / gained.length;
    }

    return DriverProfile(
      dry: _stats(dryLaps),
      wet: _stats(wetLaps),
      wetPaceLoss: paceLoss,
      dryRacePlaces: placesIn('dry'),
      wetRacePlaces: placesIn('wet'),
      dryRaces: diary.where((r) => r.conditions == 'dry').length,
      wetRaces: diary.where((r) => r.conditions == 'wet').length,
      spinHotspots: [
        for (final MapEntry(key: (track, corner), value: n) in hotspots.entries)
          if (n >= 2) (track, corner, n),
      ]..sort((a, b) => b.$3.compareTo(a.$3)),
      diary: diary,
      rounds: rounds.where((r) => r.laps.isNotEmpty).length,
    );
  }

  static ConditionStats _stats(List<PracticeLapRecord> laps) {
    final tracked = laps.where((l) => l.spinCorners != null).toList();
    double? mean(Iterable<double?> values) {
      final v = values.whereType<double>().toList();
      return v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
    }

    return ConditionStats(
      laps: laps.length,
      spinTrackedLaps: tracked.length,
      spins: tracked.fold(0, (n, l) => n + l.spinCount),
      lockupPercent: mean(laps.map((l) => l.lockupPercent)),
      wheelspinPercent: mean(laps.map((l) => l.wheelspinPercent)),
    );
  }

  /// The profile as short lines, for Boxington and the driver.
  List<String> lines() {
    if (isEmpty) return const ['No laps logged yet.'];
    final out = <String>[
      '${dry.laps + wet.laps} laps over $rounds round${rounds == 1 ? '' : 's'}: ${dry.laps} dry, ${wet.laps} wet.',
    ];
    String condition(String name, ConditionStats s) {
      final parts = <String>[
        if (s.spinsPer10Laps != null) '${s.spinsPer10Laps!.toStringAsFixed(1)} spins per 10 laps',
        if (s.lockupPercent != null) 'locking a wheel ${s.lockupPercent!.toStringAsFixed(1)}% of braking',
        if (s.wheelspinPercent != null) 'wheelspin ${s.wheelspinPercent!.toStringAsFixed(1)}% of full throttle',
      ];
      return parts.isEmpty ? '' : '$name: ${parts.join(', ')}.';
    }

    for (final line in [condition('Dry', dry), condition('Wet', wet)]) {
      if (line.isNotEmpty) out.add(line);
    }
    for (final (track, loss) in wetPaceLoss) {
      out.add('Wet pace at $track: ${loss.abs().toStringAsFixed(1)}% ${loss >= 0 ? 'slower' : 'quicker'} than dry.');
    }
    String places(double p) =>
        p.abs() < 0.5 ? 'holds position' : '${p > 0 ? 'gains' : 'loses'} ${p.abs().toStringAsFixed(1)} places';
    if (dryRacePlaces != null) out.add('Dry races ($dryRaces): ${places(dryRacePlaces!)} from lap 1 to the flag on average.');
    if (wetRacePlaces != null) out.add('Wet races ($wetRaces): ${places(wetRacePlaces!)} from lap 1 to the flag on average.');
    for (final (track, corner, n) in spinHotspots.take(3)) {
      out.add('Keeps spinning at $track corner $corner ($n times).');
    }
    return out;
  }

  /// For Boxington's system prompt: the profile and the last [races] races.
  String toPrompt({int races = 5}) => [
    ...lines(),
    if (diary.isNotEmpty) 'Recent races (newest first):',
    for (final r in diary.take(races)) '- ${r.describe()}',
  ].join('\n');

  /// Every saved round's laps.
  static Future<DriverProfile> load() async {
    final rounds = <ProfileRound>[];
    for (final summary in await PracticeLogStore.rounds()) {
      rounds.add(
        ProfileRound(
          round: summary.round,
          track: summary.track ?? summary.round,
          laps: await PracticeLogStore.loadFor(summary.round),
        ),
      );
    }
    return fromRounds(rounds);
  }

  static double _median(List<double> values) {
    final v = [...values]..sort();
    return v.length.isOdd ? v[v.length ~/ 2] : (v[v.length ~/ 2 - 1] + v[v.length ~/ 2]) / 2;
  }
}

String _cornerList(List<int> corners) {
  final known = corners.where((c) => c > 0).toList();
  if (known.isEmpty) return '';
  final counts = <int, int>{};
  for (final c in known) {
    counts[c] = (counts[c] ?? 0) + 1;
  }
  return ' (${counts.entries.map((e) => 'corner ${e.key}${e.value > 1 ? ' x${e.value}' : ''}').join(', ')})';
}

String _lapTime(int ms) {
  final m = ms ~/ 60000;
  final s = (ms % 60000) / 1000;
  return '$m:${s.toStringAsFixed(3).padLeft(6, '0')}';
}
