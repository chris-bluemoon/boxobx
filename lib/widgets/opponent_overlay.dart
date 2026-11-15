import 'package:flutter/material.dart';

import '../models/hud_overlay_data.dart';

/// Section 6: Opponent Overlay Window — shows the parsed video OCR data
/// for the car ahead and behind (name + live gap interval + whether that
/// gap is closing or growing, which is the metric not already visible
/// directly on GT7's own HUD).
class OpponentOverlay extends StatelessWidget {
  final HudOverlayData hud;

  const OpponentOverlay({super.key, required this.hud});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade800, width: 2),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _driverColumn('AHEAD', hud.driverAhead, hud.gapAheadSeconds, hud.gapAheadTrend),
          Container(width: 1, height: 48, color: Colors.grey.shade700),
          _driverColumn('BEHIND', hud.driverBehind, hud.gapBehindSeconds, hud.gapBehindTrend),
        ],
      ),
    );
  }

  Widget _driverColumn(String label, String? name, double? gapSeconds, GapTrend trend) {
    return Column(
      children: [
        Text(label, style: TextStyle(color: Colors.grey.shade500, fontSize: 14, letterSpacing: 1.2)),
        const SizedBox(height: 4),
        Text(
          name ?? '—',
          style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600),
        ),
        Text(
          gapSeconds != null ? '+${_formatGap(gapSeconds)}' : '--',
          style: TextStyle(color: _trendColor(trend), fontSize: 26, fontWeight: FontWeight.bold),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_trendIcon(trend), color: _trendColor(trend), size: 18),
            const SizedBox(width: 4),
            Text(
              _trendLabel(trend),
              style: TextStyle(color: _trendColor(trend), fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ],
    );
  }

  /// GT7's on-screen gap display is "+M:SS" for sustained gaps (e.g.
  /// "+1:51"), not decimal seconds -- mirror that format here rather
  /// than showing a raw seconds count that doesn't match what the
  /// driver sees on their own HUD.
  String _formatGap(double totalSeconds) {
    final minutes = totalSeconds ~/ 60;
    final seconds = (totalSeconds % 60).round();
    if (minutes > 0) {
      return '$minutes:${seconds.toString().padLeft(2, '0')}';
    }
    return '${seconds}s';
  }

  Color _trendColor(GapTrend trend) {
    switch (trend) {
      case GapTrend.closing:
        return Colors.greenAccent;
      case GapTrend.losing:
        return Colors.redAccent;
      case GapTrend.steady:
        return Colors.grey.shade400;
      case GapTrend.unknown:
        return Colors.grey.shade600;
    }
  }

  IconData _trendIcon(GapTrend trend) {
    switch (trend) {
      case GapTrend.closing:
        return Icons.trending_down; // gap shrinking
      case GapTrend.losing:
        return Icons.trending_up; // gap growing
      case GapTrend.steady:
        return Icons.trending_flat;
      case GapTrend.unknown:
        return Icons.remove;
    }
  }

  String _trendLabel(GapTrend trend) {
    switch (trend) {
      case GapTrend.closing:
        return 'CLOSING';
      case GapTrend.losing:
        return 'LOSING';
      case GapTrend.steady:
        return 'STEADY';
      case GapTrend.unknown:
        return '--';
    }
  }
}
