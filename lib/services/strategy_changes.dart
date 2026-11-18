import '../models/race_strategy.dart';

/// What's different between the strategy the driver had and a newly
/// generated one, in plain words -- shown in a dialog after GENERATE
/// STRATEGY, with the new plan's basis as the why.
class StrategyChanges {
  /// One line per change, e.g. "Start tyre: Heavy Wet → Intermediate".
  /// Empty when the plan is the same.
  static List<String> between(RaceStrategy old, RaceStrategy updated) {
    final changes = <String>[];
    if (old.startingTireCompound != updated.startingTireCompound) {
      changes.add('Start tyre: ${_short(old.startingTireCompound)} → ${_short(updated.startingTireCompound)}');
    }
    String stops(RaceStrategy s) =>
        s.pitStops.isEmpty ? 'no stops' : s.pitStops.map((p) => 'lap ${p.lap} ${_short(p.tireCompound)}').join(', ');
    if (stops(old) != stops(updated)) {
      changes.add(
        old.pitStops.length == updated.pitStops.length
            ? 'Stops: ${stops(old)} → ${stops(updated)}'
            : '${old.pitStops.length} → ${updated.pitStops.length} stops: ${stops(updated)} (was ${stops(old)})',
      );
    }
    if (old.fuelMap != updated.fuelMap) changes.add('Fuel Map: ${old.fuelMap} → ${updated.fuelMap}');
    if ((old.assumedPercentPerLap - updated.assumedPercentPerLap).abs() >= 0.01) {
      changes.add(
        'Fuel: ${old.assumedPercentPerLap.toStringAsFixed(2)} → ${updated.assumedPercentPerLap.toStringAsFixed(2)}%/lap',
      );
    }
    if ((old.totalEstimatedTimeLossSeconds - updated.totalEstimatedTimeLossSeconds).abs() >= 0.5) {
      changes.add(
        'Time in the pits: ${old.totalEstimatedTimeLossSeconds.toStringAsFixed(0)} → '
        '${updated.totalEstimatedTimeLossSeconds.toStringAsFixed(0)}s',
      );
    }
    if (old.validatedByPractice != updated.validatedByPractice || old.testsDone != updated.testsDone) {
      changes.add(
        updated.validatedByPractice
            ? 'Now validated: every practice stint test is done'
            : 'Stint tests done: ${old.testsDone} → ${updated.testsDone} of ${updated.testsPlanned}',
      );
    }
    return changes;
  }

  static String _short(String compound) => switch (compound) {
    'Heavy Wet' => 'Wets',
    'Intermediate' => 'Inters',
    _ => compound.replaceFirst('Racing ', ''),
  };
}
