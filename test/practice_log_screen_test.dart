// Regression test for the reported bug: deleting a lap from the
// Practice Log screen (swipe, long-press, or the delete button) did
// not actually remove the row from the list.
//
// Root cause: PracticeLapLogger.laps returns List.unmodifiable(...),
// and PracticeLogScreen's initState() assigned widget.laps directly
// to its own mutable-looking _laps field instead of copying it into a
// genuinely mutable List. _deleteLap() then called
// _laps.removeWhere(...) on that still-unmodifiable list, which threw
// an UnsupportedError at runtime and silently failed -- so the UI
// never reflected the deletion.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/screens/practice_log_screen.dart';

void main() {
  PracticeLapRecord lap(int number, DateTime recordedAt) => PracticeLapRecord(
        lapNumber: number,
        lapTimeMs: 90000 + number * 1000,
        tireCompound: 'RS',
        fuelPercentAtLapStart: 80.0,
        fuelPercentAtLapEnd: 75.0,
        recordedAt: recordedAt,
      );

  testWidgets('deleting a lap via the delete button actually removes its row', (tester) async {
    // The exact bug trigger: widget.laps is an UNMODIFIABLE list, same
    // as what PracticeLapLogger.laps really returns -- a plain mutable
    // List literal here would not have reproduced the bug at all.
    final laps = List<PracticeLapRecord>.unmodifiable([
      lap(1, DateTime(2026, 1, 1, 10, 0)),
      lap(2, DateTime(2026, 1, 1, 10, 5)),
    ]);

    DateTime? deletedAt;

    await tester.pumpWidget(MaterialApp(
      home: PracticeLogScreen(
        laps: laps,
        onClear: () {},
        onDeleteLap: (recordedAt) => deletedAt = recordedAt,
      ),
    ));
    await tester.pumpAndSettle();

    // A stint shows its summary; its laps open out on request.
    expect(find.text('L1'), findsNothing);
    await tester.tap(find.text('SHOW 2 LAPS'));
    await tester.pumpAndSettle();
    expect(find.text('L1'), findsOneWidget);
    expect(find.text('L2'), findsOneWidget);

    // Tap the delete ("x") button on lap 1's row, then confirm the
    // dialog -- same path as the reported bug (also reachable via
    // swipe-to-dismiss or long-press, all funnelling through the same
    // _deleteLap method). Rows render newest-first (laps.reversed), so
    // lap 1's delete button is the SECOND one, not .first.
    final deleteButtons = find.widgetWithIcon(IconButton, Icons.close);
    expect(deleteButtons, findsNWidgets(2));
    await tester.tap(deleteButtons.at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(deletedAt, DateTime(2026, 1, 1, 10, 0));
    // The real regression: there must only be ONE row left on screen
    // (remaining laps are renumbered sequentially, so the survivor is
    // relabeled "L1" -- asserting on the row COUNT, not the label,
    // is what actually proves the deletion took effect rather than
    // throwing silently and leaving both original rows in place).
    expect(find.widgetWithIcon(IconButton, Icons.close), findsOneWidget);
    expect(find.textContaining('PRACTICE LOG (1 LAPS)'), findsOneWidget);
  });
}
