import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/screens/splash_screen.dart';
import 'package:boxbox/widgets/box_box_logo.dart';

void main() {
  testWidgets('the splash fades the letters in, rolls the tyres in as the O\'s of BOX BOX, then fades into the app', (tester) async {
    await tester.pumpWidget(MaterialApp(home: SplashScreen(next: (_) => const Text('APP HOME'), playSound: false)));
    expect(find.byType(BoxBoxWheelWordmark), findsOneWidget);
    expect(find.byType(BoxBoxTyre), findsNWidgets(2));
    expect(find.text('RACE ENGINEER'), findsOneWidget);

    // At the start both tyres are off the left of the screen...
    Offset tyreAt(int i) => tester.getCenter(find.byType(BoxBoxTyre).at(i));
    // (getCenter reports the layout slot; the roll-in is a paint offset)
    BoxBoxWheelWordmark mark() => tester.widget(find.byType(BoxBoxWheelWordmark));
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    for (var i = 0; i < 2; i++) {
      expect(tyreAt(i).dx + mark().tyreOffsets[i], lessThan(0), reason: 'tyre $i starts off screen');
    }
    expect(mark().letters, 0);
    expect(width, greaterThan(0));
    final start = mark().tyreOffsets.toList();

    // The letters fade in first (0.6 s) -- the tyres haven't moved yet...
    await tester.pump(const Duration(milliseconds: 300));
    expect(mark().letters, inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 300)); // 0.6 s
    expect(mark().letters, closeTo(1, 0.01));
    expect(mark().tyreOffsets, start, reason: 'the tyres set off once the letters are in');
    expect(mark().taglineOpacity, 0);

    // ...then they roll into place, upright, by 1.8 s.
    await tester.pump(const Duration(milliseconds: 1200)); // 1.8 s
    expect(mark().tyreOffsets, everyElement(closeTo(0, 0.5)));
    expect(mark().tyreTurns, everyElement(closeTo(0, 0.01)));
    expect(find.text('APP HOME'), findsNothing, reason: 'still on the splash');

    // The tagline (to 2.6 s), then the finished logo holds for 2 s.
    await tester.pump(const Duration(milliseconds: 800)); // 2.6 s
    expect(mark().taglineOpacity, closeTo(1, 0.01));
    await tester.pump(const Duration(milliseconds: 16)); // a frame on: the animation's done
    await tester.pump(const Duration(milliseconds: 1184)); // 3.8 s
    expect(find.text('APP HOME'), findsNothing, reason: 'holding the finished logo');
    await tester.pump(const Duration(milliseconds: 900)); // past 4.6 s
    await tester.pumpAndSettle();
    expect(find.text('APP HOME'), findsOneWidget);
  });

  testWidgets('the tyres turn the way a tyre rolling right does, slowing to a stop', (tester) async {
    await tester.pumpWidget(MaterialApp(home: SplashScreen(next: (_) => const SizedBox(), playSound: false)));
    BoxBoxWheelWordmark mark() => tester.widget(find.byType(BoxBoxWheelWordmark));
    await tester.pump(const Duration(milliseconds: 600)); // the letters fade in first
    final turns = <double>[];
    for (var i = 0; i < 8; i++) {
      turns.add(mark().tyreTurns[0]);
      await tester.pump(const Duration(milliseconds: 150));
    }
    // Clockwise (turns rising) the whole way, by less each step.
    for (var i = 1; i < turns.length; i++) {
      expect(turns[i], greaterThanOrEqualTo(turns[i - 1]));
    }
    expect(turns[1] - turns[0], greaterThan(turns[7] - turns[6]));
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });
}
