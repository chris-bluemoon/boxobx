// Covers CornerLosses: a race's clean laps against the time-trial best,
// corner by corner.
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/corner_delta.dart';
import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/services/corner_losses.dart';

PracticeLapRecord _lap(List<CornerDelta>? deltas, {bool pit = false, List<int> spins = const []}) => PracticeLapRecord(
  lapNumber: 1,
  lapTimeMs: 90000,
  tireCompound: 'Racing Medium',
  fuelPercentAtLapStart: 50,
  fuelPercentAtLapEnd: 48,
  recordedAt: DateTime(2026, 11, 19),
  isPitLap: pit,
  spinCorners: spins,
  cornerDeltas: deltas,
);

List<CornerDelta> _deltas(int c1, int c2, int c3, {int brake2 = -15}) => [
  CornerDelta(corner: 1, ms: c1),
  CornerDelta(corner: 2, ms: c2, brakeMeters: brake2, minKmh: -6),
  CornerDelta(corner: 3, ms: c3),
];

void main() {
  test('typical loss per corner, worst first, with its share of the gap', () {
    final losses = CornerLosses.fromLaps([
      _lap(_deltas(100, 400, -50)),
      _lap(_deltas(120, 380, -40)),
      _lap(_deltas(90, 450, -60)),
    ]);
    expect(losses.laps, 3);
    expect(losses.medianLapGapMs, 460); // 450, 460, 480
    final worst = losses.worst;
    expect(worst.map((c) => c.corner), [2, 1]); // C3 gains time
    expect(worst.first.medianMs, 400);
    expect(worst.first.shareOfGapPercent, closeTo(87, 1));
    expect(worst.first.describe(), 'C2: 0.40 s a lap lost (87% of the gap), braking 15 m earlier, 6 km/h slower at the apex');
  });

  test('pit laps, spins and laps with a moment in one corner are left out', () {
    final losses = CornerLosses.fromLaps([
      _lap(_deltas(100, 400, 0)),
      _lap(_deltas(100, 400, 0)),
      _lap(_deltas(100, 400, 0)),
      _lap(_deltas(5000, 400, 0)), // an off at C1
      _lap(_deltas(900, 900, 900), pit: true),
      _lap(_deltas(900, 900, 900), spins: [2]),
      _lap(null), // no reference to compare with
    ]);
    expect(losses.laps, 3);
    expect(losses.worst.first.medianMs, 400);
  });

  test('fewer than three comparable laps: nothing to say', () {
    expect(CornerLosses.fromLaps([_lap(_deltas(1, 2, 3)), _lap(_deltas(1, 2, 3))]).isEmpty, isTrue);
  });

  test('corner deltas survive saving and loading the lap', () {
    final lap = _lap(_deltas(100, 400, -50));
    final back = PracticeLapRecord.fromMap(lap.toMap());
    expect(back.cornerDeltas!.map((c) => c.toList()), lap.cornerDeltas!.map((c) => c.toList()));
    expect(PracticeLapRecord.fromMap(_lap(null).toMap()).cornerDeltas, isNull);
  });
}
