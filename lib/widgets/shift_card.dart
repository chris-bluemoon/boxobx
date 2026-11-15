import 'package:flutter/material.dart';

import '../models/shift_event.dart';

/// Section 6: Replaces the raw GEAR digit card with a shift-habit
/// tracker -- rather than only showing a live "shift now" gauge for
/// the current instant, this shows the current gear plus a rolling
/// summary of the last few upshifts (see ShiftHistoryTracker), so the
/// driver can tell whether they're *consistently* over-revving or
/// short-shifting, not just what to do right this second.
class ShiftCard extends StatelessWidget {
  final int gear;
  final List<ShiftEvent> recentShifts;

  const ShiftCard({super.key, required this.gear, required this.recentShifts});

  static const int _dotSlots = 5;

  Color _colorFor(ShiftTiming timing) {
    switch (timing) {
      case ShiftTiming.early:
        return Colors.lightBlueAccent;
      case ShiftTiming.good:
        return Colors.greenAccent.shade400;
      case ShiftTiming.late:
        return Colors.redAccent;
    }
  }

  /// The dominant verdict across the tracked window -- the most
  /// frequent timing classification among recent shifts. Ties favour
  /// "good" (nothing to report) over calling out a pattern that isn't
  /// actually consistent yet.
  ShiftTiming? get _dominantTiming {
    if (recentShifts.isEmpty) return null;
    final counts = <ShiftTiming, int>{};
    for (final shift in recentShifts) {
      counts[shift.timing] = (counts[shift.timing] ?? 0) + 1;
    }
    final maxCount = counts.values.reduce((a, b) => a > b ? a : b);
    if ((counts[ShiftTiming.good] ?? 0) == maxCount) return ShiftTiming.good;
    return counts.entries.firstWhere((e) => e.value == maxCount).key;
  }

  String get _verdictLabel {
    switch (_dominantTiming) {
      case ShiftTiming.early:
        return 'SHORT-SHIFTING';
      case ShiftTiming.late:
        return 'OVER-REVVING';
      case ShiftTiming.good:
        return 'ON POINT';
      case null:
        return 'NO DATA';
    }
  }

  Color get _verdictColor {
    final timing = _dominantTiming;
    if (timing == null) return Colors.grey.shade500;
    return _colorFor(timing);
  }

  bool get _isOverRevving => _dominantTiming == ShiftTiming.late;

  Widget _buildDot(int index) {
    // Right-align so the most recent shift is always the rightmost dot.
    final shiftIndex = index - (_dotSlots - recentShifts.length);
    final hasShift = shiftIndex >= 0 && shiftIndex < recentShifts.length;

    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: hasShift
              ? _colorFor(recentShifts[shiftIndex].timing)
              : Colors.transparent,
          border: hasShift
              ? null
              : Border.all(color: Colors.grey.shade700, width: 1.5),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: _isOverRevving ? Colors.red.shade900 : Colors.grey.shade900,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _isOverRevving ? Colors.redAccent : Colors.grey.shade800,
          width: 2,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'GEAR',
            style: TextStyle(
              color: Colors.grey.shade400,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    gear.toString(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 56,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  // Scales down rather than overflowing when the card is short
                  // (Race Mode in landscape, above the bottom bar).
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: List.generate(_dotSlots, _buildDot),
                        ),
                        const SizedBox(height: 6),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            _verdictLabel,
                            style: TextStyle(
                              color: _verdictColor,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
