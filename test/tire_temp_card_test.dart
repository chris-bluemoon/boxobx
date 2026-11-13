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

    expect(find.text('WEAR --'), findsNWidgets(4));
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

    expect(find.text('WEAR 54%'), findsOneWidget);
    expect(find.text('WEAR 59%'), findsOneWidget);
    expect(find.text('WEAR 61%'), findsOneWidget);
    expect(find.text('WEAR 67%'), findsOneWidget);
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

    expect(find.text('WEAR 100%'), findsNWidgets(2));
    expect(find.text('WEAR --'), findsNWidgets(2));
  });
}
