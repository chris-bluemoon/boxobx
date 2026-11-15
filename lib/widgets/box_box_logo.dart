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
