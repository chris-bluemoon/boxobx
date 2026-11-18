import 'package:flutter/material.dart';

import '../models/league_calendar.dart';

/// The page heading used across the app: the circuit's emblem (its
/// outline, drawn from GT7 track data), the round and circuit as the
/// title, its dates and race notes, and the page's own heading on the
/// right, all in the page's accent colour.
class TrackHeader extends StatelessWidget {
  /// The saved round's name (e.g. "Round 4 - Alsace Village (Reverse)").
  final String? roundName;

  /// The calendar entry for that round, if it's one (see LeagueCalendar).
  final LeagueRound? round;

  /// Circuit outline in GT7 world coordinates, or null to show a
  /// round-number badge instead.
  final List<Offset>? outline;

  /// The page's own heading (e.g. "RACE MODE"), shown on the right.
  final String? pageTitle;
  final IconData? pageIcon;
  final Color accent;

  /// Tapping the page heading (e.g. back to the home page).
  final VoidCallback? onPageTitleTap;

  /// Small status dots (telemetry, HUD OCR) shown beside the page heading.
  final List<Widget> statusDots;

  /// Hero size for the home page; compact on the mode screens.
  final bool large;

  /// Tapping the header itself (the home page: pick another round). Shows
  /// a "change round" button where a page heading would go.
  final VoidCallback? onTap;

  /// A page heading that isn't about a round (the APRL standings): this
  /// title in place of the circuit, with its own overline and detail
  /// line, and [emblemIcon] in the emblem.
  final String? title;
  final String? overlineText;
  final String? details;
  final IconData? emblemIcon;

  const TrackHeader({
    super.key,
    required this.roundName,
    required this.round,
    required this.outline,
    this.title,
    this.overlineText,
    this.details,
    this.emblemIcon,
    required this.accent,
    this.pageTitle,
    this.pageIcon,
    this.onPageTitleTap,
    this.large = false,
    this.onTap,
    this.statusDots = const [],
  });

  @override
  Widget build(BuildContext context) {
    final emblemSize = large ? 132.0 : 96.0;
    final round = title == null ? this.round : null;
    final circuit = title ?? round?.circuit ?? (roundName ?? 'NO ROUND SELECTED');
    final overline = overlineText != null
        ? overlineText!
        : round == null
        ? (roundName == null
              ? (onTap == null ? 'PICK A ROUND ON THE HOME PAGE' : 'TAP TO PICK A ROUND')
              : 'CUSTOM ROUND')
        : '${LeagueCalendar.season.toUpperCase()}  ·  ${round.round.toUpperCase()}';

    final header = Container(
      padding: EdgeInsets.all(large ? 20 : 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(accent, Colors.black, 0.35)!, const Color(0xFF0B0B0F)],
          stops: const [0.0, 0.75],
        ),
        border: Border.all(color: accent.withValues(alpha: 0.6), width: 1.5),
        boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.25), blurRadius: 24, spreadRadius: -6)],
      ),
      child: Row(
        children: [
          _Emblem(
            outline: title == null ? outline : null,
            accent: accent,
            size: emblemSize,
            fallbackLabel: _badgeLabel(),
            icon: emblemIcon,
          ),
          SizedBox(width: large ? 22 : 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  overline,
                  style: TextStyle(
                    color: accent.withValues(alpha: 0.95),
                    fontSize: large ? 13 : 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2.2,
                  ),
                ),
                const SizedBox(height: 4),
                _CircuitName(circuit.toUpperCase(), fontSize: large ? 34 : 26),
                if (details != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    details!,
                    style: TextStyle(color: Colors.grey.shade300, fontSize: large ? 14 : 12, letterSpacing: 1),
                  ),
                ],
                if (round != null) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        round.dates,
                        style: TextStyle(color: Colors.grey.shade300, fontSize: large ? 14 : 12, letterSpacing: 1),
                      ),
                      if (round.featureRace) const _Tag('FEATURE RACE', Color(0xFFFFD54F), Colors.black),
                      if (round.variableWeather) const _Tag('VARIABLE WEATHER', Color(0xFF4FC3F7), Colors.black),
                      if (round.raceLengthMinutes != null)
                        _Tag('${round.raceLengthMinutes} MIN ENDURO', Colors.white, Colors.black),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (onTap != null && pageTitle == null) ...[
            const SizedBox(width: 12),
            Container(
              padding: EdgeInsets.symmetric(horizontal: large ? 16 : 12, vertical: large ? 12 : 8),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white24),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'CHANGE ROUND',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: large ? 15 : 13,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.expand_more, color: Colors.white, size: large ? 24 : 20),
                ],
              ),
            ),
          ],
          if (statusDots.isNotEmpty) ...[
            const SizedBox(width: 12),
            Row(mainAxisSize: MainAxisSize.min, children: statusDots),
          ],
          if (pageTitle != null) ...[
            const SizedBox(width: 12),
            InkWell(
              onTap: onPageTitleTap,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: large ? 18 : 14, vertical: large ? 14 : 10),
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (pageIcon != null) ...[
                      Icon(pageIcon, color: Colors.white, size: large ? 26 : 20),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      pageTitle!,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: large ? 18 : 15,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return header;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(20), child: header),
    );
  }

  /// "R4" / "FIN" for circuits with no outline data.
  String _badgeLabel() {
    final r = round?.round;
    if (r == null) return '—';
    if (r.startsWith('Round ')) return 'R${r.substring(6)}';
    return 'FIN';
  }
}

/// The circuit's name at full size if it fits; otherwise over two lines
/// (broken between words); and only if it still doesn't fit, smaller --
/// never cut off with "...".
class _CircuitName extends StatelessWidget {
  final String name;
  final double fontSize;

  const _CircuitName(this.name, {required this.fontSize});

  static const double _minFontSize = 16;

  TextStyle _style(double size) => TextStyle(
    color: Colors.white,
    fontSize: size,
    fontWeight: FontWeight.w900,
    letterSpacing: 1.0,
    height: 1.05,
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context);
      bool fits(double size) {
        final painter = TextPainter(
          text: TextSpan(text: name, style: _style(size)),
          maxLines: 2,
          textDirection: Directionality.of(context),
          textScaler: scaler,
        )..layout(maxWidth: constraints.maxWidth);
        // Two lines at most, and no single word wider than the space.
        final widest = name.split(' ').map((word) {
          final w = TextPainter(
            text: TextSpan(text: word, style: _style(size)),
            textDirection: Directionality.of(context),
            textScaler: scaler,
          )..layout();
          return w.width;
        }).fold<double>(0, (a, b) => b > a ? b : a);
        return !painter.didExceedMaxLines && widest <= constraints.maxWidth;
      }

      var size = fontSize;
      while (size > _minFontSize && !fits(size)) {
        size -= 2;
      }
      return Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: _style(size));
    },
  );
}

class _Tag extends StatelessWidget {
  final String text;
  final Color background;
  final Color foreground;

  const _Tag(this.text, this.background, this.foreground);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(4)),
    child: Text(
      text,
      style: TextStyle(color: foreground, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 1),
    ),
  );
}

/// The circuit outline in a dark tile, with a glow in the accent colour.
class _Emblem extends StatelessWidget {
  final List<Offset>? outline;
  final Color accent;
  final double size;
  final String fallbackLabel;
  final IconData? icon;

  const _Emblem({
    required this.outline,
    required this.accent,
    required this.size,
    required this.fallbackLabel,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF111116),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      padding: EdgeInsets.all(size * 0.1),
      child: icon != null
          ? Center(child: Icon(icon, color: accent, size: size * 0.5))
          : outline == null || outline!.length < 3
          ? Center(
              child: Text(
                fallbackLabel,
                style: TextStyle(color: accent, fontSize: size * 0.32, fontWeight: FontWeight.w900),
              ),
            )
          : CustomPaint(painter: TrackOutlinePainter(outline!, accent)),
    );
  }
}

/// Draws a track outline (GT7 world X/Z) fitted to the canvas, aspect
/// preserved: screen x = X, screen y = Z, which matches GT7's own course
/// map orientation.
class TrackOutlinePainter extends CustomPainter {
  final List<Offset> points;
  final Color accent;

  TrackOutlinePainter(this.points, this.accent);

  @override
  void paint(Canvas canvas, Size size) {
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    for (final p in points) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    final w = maxX - minX, h = maxY - minY;
    if (w <= 0 || h <= 0) return;
    final scale = (size.width / w) < (size.height / h) ? size.width / w : size.height / h;
    final dx = (size.width - w * scale) / 2, dy = (size.height - h * scale) / 2;
    Offset map(Offset p) => Offset(dx + (p.dx - minX) * scale, dy + (p.dy - minY) * scale);

    final path = Path()..moveTo(map(points.first).dx, map(points.first).dy);
    for (final p in points.skip(1)) {
      final m = map(p);
      path.lineTo(m.dx, m.dy);
    }
    path.close();

    final stroke = size.shortestSide * 0.045;
    canvas.drawPath(
      path,
      Paint()
        ..color = accent.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke * 2.6
        ..strokeJoin = StrokeJoin.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(TrackOutlinePainter old) => old.points != points || old.accent != accent;
}
