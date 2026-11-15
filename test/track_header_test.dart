import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/widgets/track_header.dart';

Future<Text> _name(WidgetTester tester, String name, double width) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: TrackHeader(roundName: name, round: null, outline: null, accent: Colors.red, large: true),
        ),
      ),
    ),
  ));
  expect(tester.takeException(), isNull);
  return tester.widget<Text>(find.text(name.toUpperCase()));
}

int _lines(WidgetTester tester, String name) {
  final paragraph = tester.renderObject<RenderParagraph>(find.text(name.toUpperCase()));
  return paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: name.length)).map((b) => b.top).toSet().length;
}

// Flutter's test font draws every letter as a full square (much wider than
// the real font), so these use an iPad-width header.
void main() {
  testWidgets('a short name stays one line at full size', (tester) async {
    final text = await _name(tester, 'Fuji', 700);
    expect(text.style!.fontSize, 34);
    expect(_lines(tester, 'Fuji'), 1);
  });

  testWidgets('a long name goes onto two lines at full size rather than being cut off', (tester) async {
    const name = 'Nürburgring Sprint Circuit';
    final text = await _name(tester, name, 1000);
    expect(text.style!.fontSize, 34);
    expect(_lines(tester, name), 2);
    expect(tester.renderObject<RenderParagraph>(find.text(name.toUpperCase())).didExceedMaxLines, isFalse);
  });

  testWidgets('a name too long even for two lines gets smaller, not cut off', (tester) async {
    const name = 'Autodromo Internazionale Enzo e Dino Ferrari Imola';
    final text = await _name(tester, name, 1000);
    expect(text.style!.fontSize, lessThan(34));
    expect(tester.renderObject<RenderParagraph>(find.text(name.toUpperCase())).didExceedMaxLines, isFalse);
  });
}
