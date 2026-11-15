import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/reference_lap.dart';
import '../models/time_trial_lap.dart';
import '../services/corner_report.dart';

const _lapColour = Colors.white;
const _referenceColour = Colors.purpleAccent;

String _signed(double v, {int digits = 0}) =>
    '${v > 0
        ? '+'
        : v < 0
        ? '−'
        : '±'}${v.abs().toStringAsFixed(digits)}';

/// The last clean lap against the reference lap, corner by corner: time
/// lost or gained, entry / minimum / exit speed and braking. Tap a row to
/// see that corner on the map (both brake points marked); tap the map to
/// zoom back out.
class CornerReportScreen extends StatefulWidget {
  final CornerReport report;

  const CornerReportScreen({super.key, required this.report});

  @override
  State<CornerReportScreen> createState() => _CornerReportScreenState();
}

class _CornerReportScreenState extends State<CornerReportScreen> {
  bool _biggestLossFirst = false;
  CornerResult? _selected;

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final rows = [...report.corners];
    if (_biggestLossFirst) rows.sort((a, b) => b.timeDeltaMs.compareTo(a.timeDeltaMs));
    final gap = report.lapDeltaMs / 1000;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('CORNER REPORT')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text.rich(
                TextSpan(
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                  children: [
                    const TextSpan(text: 'Last lap  '),
                    TextSpan(
                      text: TimeTrialLap.format(report.lap.lapTimeMs),
                      style: const TextStyle(color: _lapColour, fontWeight: FontWeight.bold),
                    ),
                    const TextSpan(text: '   ·   reference  '),
                    TextSpan(
                      text: TimeTrialLap.format(report.reference.lapTimeMs),
                      style: const TextStyle(color: _referenceColour, fontWeight: FontWeight.bold),
                    ),
                    TextSpan(
                      text: '   ·   ${_signed(gap, digits: 3)}s',
                      style: TextStyle(color: _gainLoss(report.lapDeltaMs.toDouble()), fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                flex: 4,
                child: GestureDetector(
                  onTap: () => setState(() => _selected = null),
                  child: Container(
                    decoration: BoxDecoration(color: Colors.grey.shade900, borderRadius: BorderRadius.circular(16)),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(painter: CornerMapPainter(report, selected: _selected)),
                        ),
                        Positioned(
                          left: 10,
                          bottom: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              _selected == null
                                  ? 'Tap a corner below to zoom in'
                                  : 'C${_selected!.corner.number}  ·  ● brake point: white = last lap, purple = reference  ·  tap to zoom out',
                              style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    'CORNERS',
                    style: TextStyle(color: Colors.grey.shade400, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('TRACK ORDER')),
                      ButtonSegment(value: true, label: Text('BIGGEST LOSS')),
                    ],
                    selected: {_biggestLossFirst},
                    onSelectionChanged: (s) => setState(() => _biggestLossFirst = s.first),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _headerRow(),
              Expanded(
                flex: 5,
                child: ListView(
                  children: [
                    for (final result in rows)
                      _CornerRow(
                        result: result,
                        selected: identical(result, _selected),
                        onTap: () => setState(() => _selected = identical(result, _selected) ? null : result),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerRow() {
    final style = TextStyle(color: Colors.grey.shade500, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 1);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 72, child: Text('CORNER', style: style)),
          SizedBox(width: 84, child: Text('TIME', style: style)),
          for (final h in ['ENTRY km/h', 'MIN km/h', 'EXIT km/h', 'BRAKE POINT', 'PEAK BRAKE', 'BRAKE ZONE'])
            Expanded(child: Text(h, style: style)),
        ],
      ),
    );
  }
}

Color _gainLoss(double deltaMs) => deltaMs.abs() < 5
    ? Colors.white
    : deltaMs > 0
    ? Colors.redAccent
    : Colors.greenAccent;

class _CornerRow extends StatelessWidget {
  final CornerResult result;
  final bool selected;
  final VoidCallback onTap;

  const _CornerRow({required this.result, required this.selected, required this.onTap});

  /// A value with the reference's (or the difference) underneath.
  Widget _cell(String value, String? under, {Color? underColour}) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
        ),
        Text(under ?? '', style: TextStyle(color: underColour ?? Colors.grey.shade500, fontSize: 14)),
      ],
    ),
  );

  /// Speed with its difference to the reference (faster = green).
  Widget _speed(double lap, double reference) {
    final d = lap - reference;
    return _cell(
      lap.round().toString(),
      d.abs() < 1 ? 'same' : '${_signed(d)} vs ref',
      underColour: d.abs() < 1 ? null : (d > 0 ? Colors.greenAccent : Colors.redAccent),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lapBrake = result.lap.braking, refBrake = result.reference.braking;
    final brakeDelta = result.brakeDeltaMeters;
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? Colors.white : Colors.transparent, width: 2),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 72,
              child: Text(
                'C${result.corner.number}',
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            SizedBox(
              width: 84,
              child: Text(
                '${_signed(result.timeDeltaMs / 1000, digits: 3)}s',
                style: TextStyle(color: _gainLoss(result.timeDeltaMs), fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            _speed(result.lap.entryKmh, result.reference.entryKmh),
            _speed(result.lap.minKmh, result.reference.minKmh),
            _speed(result.lap.exitKmh, result.reference.exitKmh),
            _cell(
              brakeDelta == null
                  ? (lapBrake == null ? 'no brake' : 'braked')
                  : brakeDelta.abs() < 1
                  ? 'same'
                  : '${brakeDelta.abs().round()} m ${brakeDelta < 0 ? 'early' : 'late'}',
              refBrake == null ? 'ref: no brake' : 'vs reference',
            ),
            _cell(
              lapBrake == null ? '--' : '${lapBrake.peakPercent}%',
              refBrake == null ? null : 'ref ${refBrake.peakPercent}%',
            ),
            _cell(
              lapBrake == null ? '--' : '${lapBrake.zoneMeters.round()} m',
              refBrake == null ? null : 'ref ${refBrake.zoneMeters.round()} m',
            ),
          ],
        ),
      ),
    );
  }
}

/// The reference lap's line (purple) and the last lap's (white) with the
/// corner numbers; zoomed to [selected]'s stretch, with both brake points
/// and the apex marked.
class CornerMapPainter extends CustomPainter {
  final CornerReport report;
  final CornerResult? selected;

  CornerMapPainter(this.report, {this.selected});

  @override
  void paint(Canvas canvas, Size size) {
    final ref = report.reference;
    if (ref.length < 2) return;

    // What to fit: the whole lap, or the selected corner's stretch.
    final focus = <Offset>[];
    final pick = selected;
    final (viewFrom, viewTo) = pick?.viewRange ?? (0.0, 0.0);
    for (var i = 0; i < ref.length; i++) {
      final d = ref.distances[i];
      if (pick == null || (d >= viewFrom && d <= viewTo)) {
        focus.add(Offset(ref.xs[i], ref.zs[i]));
      }
    }
    if (focus.isEmpty) return;
    var minX = focus.first.dx, maxX = minX, minY = focus.first.dy, maxY = minY;
    for (final p in focus) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    const pad = 28.0;
    final spanX = math.max(maxX - minX, 30), spanY = math.max(maxY - minY, 30);
    final scale = math.min((size.width - pad * 2) / spanX, (size.height - pad * 2) / spanY);
    final cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
    Offset toScreen(double x, double z) =>
        Offset(size.width / 2 + (x - cx) * scale, size.height / 2 + (z - cy) * scale);

    Path line(ReferenceLap trace) {
      final path = Path()..moveTo(toScreen(trace.xs[0], trace.zs[0]).dx, toScreen(trace.xs[0], trace.zs[0]).dy);
      for (var i = 1; i < trace.length; i++) {
        final p = toScreen(trace.xs[i], trace.zs[i]);
        path.lineTo(p.dx, p.dy);
      }
      return path;
    }

    final zoomed = pick != null;
    canvas.drawPath(
      line(ref),
      Paint()
        ..color = _referenceColour.withValues(alpha: zoomed ? 0.9 : 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = zoomed ? 4 : 3
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      line(report.lap),
      Paint()
        ..color = _lapColour.withValues(alpha: zoomed ? 0.9 : 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = zoomed ? 2 : 1.5
        ..strokeJoin = StrokeJoin.round,
    );

    void label(String text, Offset at, {Color colour = Colors.white, double fontSize = 12}) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: colour, fontSize: fontSize, fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, at - Offset(painter.width / 2, painter.height / 2));
    }

    if (!zoomed) {
      for (final r in report.corners) {
        final p = toScreen(r.corner.x, r.corner.z);
        canvas.drawCircle(p, 11, Paint()..color = Colors.black.withValues(alpha: 0.75));
        label('${r.corner.number}', p, colour: r.timeDeltaMs > 20 ? Colors.redAccent : Colors.white, fontSize: 13);
      }
      return;
    }

    void brakeMark(CornerBraking? b, Color colour) {
      if (b == null) return;
      final p = toScreen(b.x, b.z);
      canvas.drawCircle(p, 8, Paint()..color = colour);
      canvas.drawCircle(
        p,
        8,
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    brakeMark(pick.reference.braking, _referenceColour);
    brakeMark(pick.lap.braking, _lapColour);
    final apex = toScreen(pick.corner.x, pick.corner.z);
    canvas.drawCircle(apex, 14, Paint()..color = Colors.black.withValues(alpha: 0.75));
    label('C${pick.corner.number}', apex, fontSize: 14);
  }

  @override
  bool shouldRepaint(CornerMapPainter old) => old.report != report || old.selected != selected;
}
