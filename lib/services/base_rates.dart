import '../models/practice_lap_record.dart';
import '../models/race_briefing.dart';
import 'practice_log_store.dart';
import 'track_database.dart';

/// One earlier round's laps, with what they were driven under.
class RoundLaps {
  final String track;
  final double trackLengthMeters;
  final double fuelMultiplier;
  final double tyreWearMultiplier;
  final List<PracticeLapRecord> laps;

  const RoundLaps({
    required this.track,
    required this.trackLengthMeters,
    required this.fuelMultiplier,
    required this.tyreWearMultiplier,
    required this.laps,
  });
}

/// A rate measured from the driver's own laps, per lap per 1x multiplier
/// per km of track -- so it carries over to a round with a different
/// multiplier and lap length.
class BaseRate {
  final double perXPerKm;

  /// The tracks it was measured at, and how many laps went in.
  final List<String> tracks;
  final int laps;

  const BaseRate({required this.perXPerKm, required this.tracks, required this.laps});

  /// Per lap at [multiplier] on a [trackLengthMeters] lap.
  double perLap(double multiplier, double trackLengthMeters) => perXPerKm * multiplier * trackLengthMeters / 1000;
}

/// Fuel use and tyre wear from the driver's laps in every round so far,
/// scaled to a 1x multiplier and a 1 km lap. The strategy for a new
/// round starts from these (scaled back to its multipliers and track
/// length) until practice laps there measure it directly. Worked out
/// afresh each time, so every round driven adds to them.
class BaseRates {
  final BaseRate? fuel;

  /// Tyre wear (percent of the tyre per lap) by compound.
  final Map<String, BaseRate> wear;

  const BaseRates({this.fuel, this.wear = const {}});

  static const BaseRates none = BaseRates();

  /// Fewer laps than this (fuel) or lap-to-lap readings (a compound's
  /// wear) and the figure isn't used.
  static const int minFuelLaps = 3;
  static const int minWearLaps = 3;

  /// A tyre-wear reading this far from both neighbours is a misread.
  static const double wearSpikePercent = 15;

  static BaseRates fromRounds(List<RoundLaps> rounds) {
    var fuelSum = 0.0;
    var fuelLaps = 0;
    final fuelTracks = <String>[];
    final wearSum = <String, double>{};
    final wearLaps = <String, int>{};
    final wearTracks = <String, List<String>>{};

    for (final round in rounds) {
      final km = round.trackLengthMeters / 1000;
      if (km <= 0) continue;

      if (round.fuelMultiplier > 0) {
        // Laps that used fuel: no pit laps (a refuel), and none with the
        // fuel switched off (a qualifying run sits at 100%).
        final used = [
          for (final lap in round.laps)
            if (!lap.isPitLap && lap.fuelConsumedPercent > 0) lap.fuelConsumedPercent,
        ];
        if (used.isNotEmpty) {
          fuelSum += used.fold<double>(0, (a, b) => a + b) / (round.fuelMultiplier * km);
          fuelLaps += used.length;
          if (!fuelTracks.contains(round.track)) fuelTracks.add(round.track);
        }
      }

      if (round.tyreWearMultiplier > 0) {
        for (final (compound, drop, laps) in _wearByStint(round.laps)) {
          wearSum[compound] = (wearSum[compound] ?? 0) + drop / (round.tyreWearMultiplier * km);
          wearLaps[compound] = (wearLaps[compound] ?? 0) + laps;
          final tracks = wearTracks.putIfAbsent(compound, () => []);
          if (!tracks.contains(round.track)) tracks.add(round.track);
        }
      }
    }

    return BaseRates(
      fuel: fuelLaps >= minFuelLaps ? BaseRate(perXPerKm: fuelSum / fuelLaps, tracks: fuelTracks, laps: fuelLaps) : null,
      wear: {
        for (final compound in wearSum.keys)
          if (wearLaps[compound]! >= minWearLaps)
            compound: BaseRate(
              perXPerKm: wearSum[compound]! / wearLaps[compound]!,
              tracks: wearTracks[compound]!,
              laps: wearLaps[compound]!,
            ),
      },
    );
  }

  /// Each stint's tyre wear: (compound, percent worn, laps it took),
  /// from the gauge readings at the end of its laps -- pit laps (the old
  /// set's last reading, or the new set settling) and misread spikes
  /// left out.
  static List<(String, double, int)> _wearByStint(List<PracticeLapRecord> laps) {
    final byStint = <int, List<PracticeLapRecord>>{};
    for (final lap in laps) {
      byStint.putIfAbsent(lap.stintNumber, () => []).add(lap);
    }
    final result = <(String, double, int)>[];
    for (final stint in byStint.values) {
      final readings = [
        for (final lap in stint)
          if (!lap.isPitLap && lap.tireWearPercent != null && lap.tireWearPercent! > 0) lap,
      ];
      final clean = [
        for (var i = 0; i < readings.length; i++)
          if (!_isSpike(readings, i)) readings[i],
      ];
      if (clean.length < 2) continue;
      final first = clean.first;
      final last = clean.last;
      final laps = last.lapNumber - first.lapNumber;
      final drop = first.tireWearPercent! - last.tireWearPercent!;
      if (laps <= 0 || drop < 0) continue;
      // The stint's most common compound (a lap can carry a misread).
      final counts = <String, int>{};
      for (final lap in stint) {
        counts[lap.tireCompound] = (counts[lap.tireCompound] ?? 0) + 1;
      }
      final compound = counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
      result.add((compound, drop, laps));
    }
    return result;
  }

  static bool _isSpike(List<PracticeLapRecord> readings, int i) {
    final value = readings[i].tireWearPercent!;
    final before = i > 0 ? readings[i - 1].tireWearPercent! : null;
    final after = i < readings.length - 1 ? readings[i + 1].tireWearPercent! : null;
    if (before == null && after == null) return false;
    return (before == null || (value - before).abs() > wearSpikePercent) &&
        (after == null || (value - after).abs() > wearSpikePercent);
  }

  /// Every saved round with laps and a brief on a track of known length.
  static Future<BaseRates> load() async {
    final tracks = await TrackDatabase.load();
    final rounds = <RoundLaps>[];
    for (final summary in await PracticeLogStore.rounds()) {
      final RaceBriefing? brief = summary.briefing;
      if (brief == null) continue;
      final length = tracks.where((t) => t.name == brief.trackName).map((t) => t.trackLengthMeters).firstOrNull;
      if (length == null) continue;
      rounds.add(
        RoundLaps(
          track: brief.trackName,
          trackLengthMeters: length,
          fuelMultiplier: brief.fuelConsumptionMultiplier,
          tyreWearMultiplier: brief.tyreWearMultiplier,
          laps: await PracticeLogStore.loadFor(summary.round),
        ),
      );
    }
    return fromRounds(rounds);
  }
}
