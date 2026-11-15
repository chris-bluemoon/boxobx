import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Racing red used by the Box Box brand.
const Color boxBoxRed = Color(0xFFE8202A);

/// The Box Box logo: a tyre emblem beside the "BOX BOX" wordmark, with
/// the tagline underneath.
///
/// The emblem is a tyre sidewall with a red compound stripe (as on a
/// soft racing tyre). The wordmark is
/// Barlow Condensed ExtraBold Italic: the first BOX white, the second
/// red -- the radio call, said twice.
///
/// For the splash animation, [tyreTurns] spins the tyre, [stripe] (0-1)
/// sweeps the compound stripe round it, and [taglineOpacity] fades the
/// tagline in; all default to the finished logo. [size] is the
/// wordmark's font size; the emblem spans the wordmark and tagline.
class BoxBoxLogo extends StatelessWidget {
  final double size;
  final double tyreTurns;
  final double stripe;
  final double taglineOpacity;

  /// The line under the wordmark.
  final String tagline;

  const BoxBoxLogo({
    super.key,
    this.size = 96,
    this.tyreTurns = 0,
    this.stripe = 1,
    this.taglineOpacity = 1,
    this.tagline = 'RACE ENGINEER',
  });

  static const _family = 'BarlowCondensed';

  @override
  Widget build(BuildContext context) {
    final word = TextStyle(
      fontFamily: _family,
      fontSize: size,
      fontWeight: FontWeight.w800,
      fontStyle: FontStyle.italic,
      height: 0.9,
      letterSpacing: size * 0.01,
    );
    final emblem = size * 1.12;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Transform.rotate(
          angle: tyreTurns * 2 * math.pi,
          child: SizedBox.square(
            dimension: emblem,
            child: CustomPaint(painter: _TyrePainter(stripe: stripe.clamp(0.0, 1.0))),
          ),
        ),
        SizedBox(width: size * 0.22),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: 'BOX ', style: word.copyWith(color: Colors.white)),
                  TextSpan(text: 'BOX', style: word.copyWith(color: boxBoxRed)),
                ],
              ),
            ),
            SizedBox(height: size * 0.1),
            Opacity(
              opacity: taglineOpacity.clamp(0.0, 1.0),
              child: Padding(
                padding: EdgeInsets.only(left: size * 0.04),
                child: Text(
                  tagline,
                  style: TextStyle(
                    fontFamily: _family,
                    color: Colors.white70,
                    // Never below 11 px, so it stays readable small.
                    fontSize: math.max(size * 0.21, 11),
                    fontWeight: FontWeight.w600,
                    height: 1.0,
                    letterSpacing: math.max(size * 0.21, 11) * 0.28,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The Box Box tyre on its own: [diameter] across, turned [turns] (1 = a
/// full turn, clockwise), with [stripe] (0-1) of the compound stripe drawn.
class BoxBoxTyre extends StatelessWidget {
  final double diameter;
  final double turns;
  final double stripe;

  const BoxBoxTyre({super.key, required this.diameter, this.turns = 0, this.stripe = 1});

  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: turns * 2 * math.pi,
    child: SizedBox.square(
      dimension: diameter,
      child: CustomPaint(painter: _TyrePainter(stripe: stripe.clamp(0.0, 1.0))),
    ),
  );
}

/// The splash's wordmark: "BOX BOX" with tyres for the O's. Each tyre is
/// placed by [tyreOffsets] (px from its O's slot -- negative is to the
/// left) and turned by [tyreTurns]; [letters] (0-1) fades the B's and
/// X's in, and [taglineOpacity] the tagline. The defaults are the
/// finished mark.
class BoxBoxWheelWordmark extends StatelessWidget {
  final double size;
  final List<double> tyreOffsets;
  final List<double> tyreTurns;
  final double letters;
  final double taglineOpacity;
  final String tagline;

  const BoxBoxWheelWordmark({
    super.key,
    this.size = 110,
    this.tyreOffsets = const [0, 0],
    this.tyreTurns = const [0, 0],
    this.letters = 1,
    this.taglineOpacity = 1,
    this.tagline = 'RACE ENGINEER',
  });

  /// The tyre's diameter as a share of the font size: Barlow Condensed's
  /// cap height, so a tyre stands exactly as tall as the B and X.
  static const double tyreScale = 0.7;

  @override
  Widget build(BuildContext context) {
    final word = TextStyle(
      fontFamily: BoxBoxLogo._family,
      fontSize: size,
      fontWeight: FontWeight.w800,
      fontStyle: FontStyle.italic,
      height: 1.0,
      letterSpacing: size * 0.01,
    );
    final fade = letters.clamp(0.0, 1.0);
    TextSpan letter(String text, Color colour) =>
        TextSpan(text: text, style: word.copyWith(color: colour.withValues(alpha: colour.a * fade)));
    InlineSpan tyre(int i) => WidgetSpan(
      // Bottom on the baseline: the tyre sits on the line with the letters.
      alignment: PlaceholderAlignment.aboveBaseline,
      baseline: TextBaseline.alphabetic,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: size * 0.035),
        child: Transform.translate(
          offset: Offset(tyreOffsets[i], 0),
          child: BoxBoxTyre(diameter: size * tyreScale, turns: tyreTurns[i]),
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text.rich(
          TextSpan(
            children: [
              letter('B', Colors.white),
              tyre(0),
              letter('X ', Colors.white),
              letter('B', boxBoxRed),
              tyre(1),
              letter('X', boxBoxRed),
            ],
          ),
        ),
        SizedBox(height: size * 0.12),
        Opacity(
          opacity: taglineOpacity.clamp(0.0, 1.0),
          child: Text(
            tagline,
            style: TextStyle(
              fontFamily: BoxBoxLogo._family,
              color: Colors.white70,
              fontSize: math.max(size * 0.21, 11),
              fontWeight: FontWeight.w600,
              height: 1.0,
              letterSpacing: math.max(size * 0.21, 11) * 0.28,
            ),
          ),
        ),
      ],
    );
  }
}

/// A tyre seen side-on, drawn flat: a white tread ring and, inside it,
/// the red compound stripe in two arcs (broken where the sidewall
/// lettering would be, so the spin reads). [stripe] (0-1) is how much
/// of each arc is drawn.
class _TyrePainter extends CustomPainter {
  final double stripe;

  const _TyrePainter({required this.stripe});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;

    // Tread: a white ring.
    canvas.drawCircle(
      c,
      r * 0.88,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.24,
    );

    // Compound stripe: a bold red band on the sidewall, broken in two
    // short gaps (where the lettering would be) so the spin reads.
    if (stripe > 0) {
      final band = Paint()
        ..color = boxBoxRed
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.2
        ..strokeCap = StrokeCap.butt;
      final rect = Rect.fromCircle(center: c, radius: r * 0.56);
      const gap = 0.42; // radians
      const lean = 0.21; // gaps tilted to the italic lettering's slant
      for (final start in [-math.pi / 2 + lean + gap / 2, math.pi / 2 + lean + gap / 2]) {
        canvas.drawArc(rect, start, (math.pi - gap) * stripe, false, band);
      }
    }

    // Wheel nut.
    canvas.drawCircle(c, r * 0.16, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_TyrePainter oldDelegate) => oldDelegate.stripe != stripe;
}
