import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/screens/splash_screen.dart';
import 'package:boxbox/widgets/box_box_logo.dart';

void main() {
  testWidgets('the splash shows the Box Box logo, then fades into the app', (tester) async {
    await tester.pumpWidget(MaterialApp(home: SplashScreen(next: (_) => const Text('APP HOME'))));
    expect(find.byType(BoxBoxLogo), findsOneWidget);
    expect(find.text('RACE ENGINEER'), findsOneWidget);
    expect(find.text('APP HOME'), findsNothing);

    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text('APP HOME'), findsNothing, reason: 'still on the splash');

    await tester.pump(const Duration(milliseconds: 800)); // past 2.2s
    await tester.pumpAndSettle();
    expect(find.text('APP HOME'), findsOneWidget);
    expect(find.byType(BoxBoxLogo), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
