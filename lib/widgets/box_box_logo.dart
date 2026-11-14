import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Racing red used by the Box Box brand.
const Color boxBoxRed = Color(0xFFE8202A);

/// The Box Box logo: "BOX BOX" in heavy italic with each O drawn as a
/// racing tyre (red rim, tread blocks), over a red stripe with "RACE
/// ENGINEER". [tyreTurns] spins the tyres and [stripe] (0-1) sweeps the
/// stripe in, for the splash animation; both default to the finished
/// logo.
class BoxBoxLogo extends StatelessWidget {
  final double size;
  final double tyreTurns;
  final double stripe;
  final double taglineOpacity;

  /// The line under the stripe.
  final String tagline;

  const BoxBoxLogo({
    super.key,
    this.size = 96,
    this.tyreTurns = 0,
    this.stripe = 1,
    this.taglineOpacity = 1,
    this.tagline = 'RACE ENGINEER',
  });

  @override
  Widget build(BuildContext context) {
    final letter = TextStyle(
      color: Colors.white,
      fontSize: size,
      fontWeight: FontWeight.w900,
      fontStyle: FontStyle.italic,
      height: 1.0,
      letterSpacing: -size * 0.02,
    );
    Widget tyre() => Padding(
      padding: EdgeInsets.only(left: size * 0.06, right: size * 0.03),
      child: Transform(
        // Lean the tyre with the italic lettering.
        transform: Matrix4.skewX(-0.2),
        alignment: Alignment.center,
        child: Transform.rotate(
          angle: tyreTurns * 2 * math.pi,
          child: SizedBox.square(
            dimension: size * 0.74,
            child: const CustomPaint(painter: _TyrePainter()),
          ),
        ),
      ),
    );
    Widget word() => Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text('B', style: letter),
        tyre(),
        Text('X', style: letter),
      ],
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            word(),
            SizedBox(width: size * 0.28),
            word(),
          ],
        ),
        SizedBox(height: size * 0.16),
        // Red stripe, swept in from the left.
        SizedBox(
          width: size * 5.6,
          height: size * 0.07,
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: stripe.clamp(0.0, 1.0),
              child: Transform(
                transform: Matrix4.skewX(-0.6),
                child: Container(color: boxBoxRed),
              ),
            ),
          ),
        ),
        SizedBox(height: size * 0.14),
        Opacity(
          opacity: taglineOpacity.clamp(0.0, 1.0),
          child: Text(
            tagline,
            style: TextStyle(
              color: Colors.white70,
              fontSize: size * 0.17,
              fontWeight: FontWeight.w700,
              letterSpacing: size * 0.09,
            ),
          ),
        ),
      ],
    );
  }
}

/// A tyre seen side-on: white sidewall ring with tread blocks round the
/// outside, a red rim band, and a dark hub.
class _TyrePainter extends CustomPainter {
  const _TyrePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;

    // Tyre: a solid white ring with tread grooves cut across it.
    canvas.drawCircle(
      c,
      r * 0.78,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.42,
    );
    final groove = Paint()
      ..color = Colors.black
      ..strokeWidth = r * 0.07
      ..strokeCap = StrokeCap.round;
    const grooves = 20;
    for (var i = 0; i < grooves; i++) {
      final a = i * 2 * math.pi / grooves;
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + dir * r * 0.84, c + dir * r * 0.97, groove);
    }
    // Red rim band.
    canvas.drawCircle(
      c,
      r * 0.5,
      Paint()
        ..color = boxBoxRed
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.12,
    );
    // Spokes and hub.
    final spoke = Paint()
      ..color = Colors.white
      ..strokeWidth = r * 0.07
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 5; i++) {
      final a = i * 2 * math.pi / 5 - math.pi / 2;
      canvas.drawLine(
        c + Offset(math.cos(a), math.sin(a)) * r * 0.14,
        c + Offset(math.cos(a), math.sin(a)) * r * 0.42,
        spoke,
      );
    }
    canvas.drawCircle(c, r * 0.12, Paint()..color = boxBoxRed);
  }

  @override
  bool shouldRepaint(_TyrePainter oldDelegate) => false;
}
