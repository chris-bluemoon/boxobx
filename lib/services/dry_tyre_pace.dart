import 'dart:math' as math;

import '../models/practice_lap_record.dart';
import 'pit_stop_calculator.dart';
import 'stint_summary.dart';
import 'wet_pace_table.dart';

/// A dry compound's pace this round, from practice: the typical lap
/// (median of the counted laps) of the longest full-tank Map 1 stint on
/// it (the latest, of equal ones) -- a couple of laps out of a later run
/// say less than a whole tank, and -- if a stint on it lost pace -- how many laps it held on for.
class DryTyrePace {
  final String compound;
  final double lapMs;
  final int laps;

  /// The fewest laps a stint on this tyre held its pace for before it
  /// went off (StintSummary.tyreDropOff), or null if it never did.
  final int? dropOffAfterLaps;

  /// The longest stint on this tyre that held its pace throughout (long
  /// enough to have shown a drop-off: StintSummary.dropOffMinLaps), and
  /// how worn the tyres were at its end (percent worn, if logged).
  final int? heldPaceLaps;
  final double? heldPaceWornPercent;

  const DryTyrePace(this.compound, this.lapMs, this.laps, {this.dropOffAfterLaps, this.heldPaceLaps, this.heldPaceWornPercent});

  /// A stint needs this many counted laps to give a pace.
  static const int minLaps = 2;

  /// Stints started on less fuel than this are left out: a light car is
  /// quicker, so a low-fuel run would flatter its tyre.
  static const double minStartFuelPercent = 80;

  /// Dry tyres by compound, from this round's practice [laps]. Wet
  /// running, race laps, fuel-map runs and low-fuel runs are left out,
  /// so every compound is timed the same way.
  static Map<String, DryTyrePace> fromLaps(List<PracticeLapRecord> laps) {
    final result = <String, DryTyrePace>{};
    final dropOff = <String, int>{};
    final held = <String, (int, double?)>{};
    // StintSummary lists newest first: a stint replaces the one kept only
    // if it has more laps, so of equal ones the latest stays.
    for (final stint in StintSummary.fromLaps(laps)) {
      if (stint.stintNumber == 0 || stint.isRace) continue;
      final compound = stint.tyreCompound;
      if (!PitStopCalculator.dryCompounds.contains(compound)) continue;
      if (stint.weatherLevel != 'DRY') continue;
      if (stint.laps.any((l) => (l.waterPercent ?? 0) >= WetPaceTable.wetTrackPercent)) continue;
      if (stint.laps.any((l) => (l.fuelMap ?? 1) > 1)) continue;
      final first = stint.laps.where((l) => !l.isPitLap).firstOrNull;
      if (first == null || first.fuelPercentAtLapStart < minStartFuelPercent) continue;
      if (stint.tyreDropOff case final d?) {
        dropOff[compound] = math.min(dropOff[compound] ?? d.lapsBeforeDropOff, d.lapsBeforeDropOff);
      } else if (stint.lapCount >= StintSummary.dropOffMinLaps && stint.lapCount > (held[compound]?.$1 ?? 0)) {
        final wear = stint.laps.lastWhere((l) => !l.isPitLap, orElse: () => stint.laps.last).tireWearPercent;
        held[compound] = (stint.lapCount, wear == null || wear <= 0 ? null : 100 - wear);
      }
      if (stint.lapCount < minLaps || stint.lapCount <= (result[compound]?.laps ?? 0)) continue;
      final pace = stint.typicalLapMs;
      if (pace == null) continue;
      result[compound] = DryTyrePace(compound, pace, stint.lapCount);
    }
    return {
      for (final MapEntry(key: c, value: p) in result.entries)
        c: DryTyrePace(c, p.lapMs, p.laps, dropOffAfterLaps: dropOff[c], heldPaceLaps: held[c]?.$1, heldPaceWornPercent: held[c]?.$2),
      // A tyre that went off but has no pace stint of its own still
      // tells how long it lasts.
      for (final MapEntry(key: c, value: n) in dropOff.entries)
        if (!result.containsKey(c)) c: DryTyrePace(c, 0, 0, dropOffAfterLaps: n),
    };
  }

  bool get hasPace => laps > 0;
}
