import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/widgets/tire_temp_card.dart';

void main() {
  testWidgets('shows -- for wear when tireWearPercents is omitted (defaults to all-null)', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TireTempCard(tireTemps: [80, 82, 79, 81]),
      ),
    ));

    expect(find.text('--'), findsNWidgets(4));
    expect(find.text('WEAR '), findsNWidgets(4));
    expect(find.text('80°'), findsOneWidget);
  });

  testWidgets('shows each wheel\'s wear percent when provided by OCR', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TireTempCard(
          tireTemps: [80, 82, 79, 81],
          tireWearPercents: [54.05, 59.46, 61.11, 66.67],
        ),
      ),
    ));

    expect(find.text('54%'), findsOneWidget);
    expect(find.text('59%'), findsOneWidget);
    expect(find.text('61%'), findsOneWidget);
    expect(find.text('67%'), findsOneWidget);
  });

  testWidgets('does not overflow when the card is given a tight height (regression)', (tester) async {
    // Reproduces the reported real-device bug: the WEAR line added a
    // 3rd fixed-height Text to each corner's label+temp pair, and on a
    // real iPad's actual (tighter than the simulator's) card height
    // that combined fixed height overflowed the available space by
    // ~37px. 90px is deliberately tight enough to trigger the old bug
    // (label + 26px temp + wear line all at fixed size) while still
    // being a plausible real on-screen card height.
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 90,
          width: 300,
          child: TireTempCard(
            tireTemps: [80, 82, 79, 81],
            tireWearPercents: [54.05, 59.46, 61.11, 66.67],
          ),
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
  });

  testWidgets('shows -- for just the wheels OCR could not read, keeping the others', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TireTempCard(
          tireTemps: [80, 82, 79, 81],
          tireWearPercents: [100.0, null, 100.0, null],
        ),
      ),
    ));

    expect(find.text('100%'), findsNWidgets(2));
    expect(find.text('--'), findsNWidgets(2));
  });
}
