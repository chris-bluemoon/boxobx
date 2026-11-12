import 'package:flutter/material.dart';

/// Section 6: Replaces the SPEED card with a 2x2 tire-temperature
/// readout mirroring the car's physical layout (front pair on top,
/// rear pair below). Colour bands are GT7-specific (validated against
/// racing-compound tire behaviour): below 70C the tire is too cold for
/// ideal grip, 70-95C is the optimal working window, above 95C the
/// tire is overheating and degrading faster.
class TireTempCard extends StatelessWidget {
  /// [FL, FR, RL, RR] in degrees Celsius.
  final List<double> tireTemps;

  const TireTempCard({super.key, required this.tireTemps});

  static const double _coldThreshold = 70;
  static const double _hotThreshold = 95;

  Color _colorFor(double tempC) {
    if (tempC <= 0) return Colors.grey.shade700;
    if (tempC < _coldThreshold) return Colors.lightBlueAccent;
    if (tempC > _hotThreshold) return Colors.redAccent;
    return Colors.greenAccent.shade400;
  }

  bool get _anyOverheating => tireTemps.any((t) => t > _hotThreshold);

  Widget _corner(String label, double tempC) {
    final color = _colorFor(tempC);
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.grey.shade500,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              tempC <= 0 ? '--' : tempC.toStringAsFixed(0),
              style: TextStyle(
                color: color,
                fontSize: 26,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fl = tireTemps.isNotEmpty ? tireTemps[0] : 0.0;
    final fr = tireTemps.length > 1 ? tireTemps[1] : 0.0;
    final rl = tireTemps.length > 2 ? tireTemps[2] : 0.0;
    final rr = tireTemps.length > 3 ? tireTemps[3] : 0.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: _anyOverheating ? Colors.red.shade900 : Colors.grey.shade900,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _anyOverheating ? Colors.redAccent : Colors.grey.shade800,
          width: 2,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'TYRE TEMP',
            style: TextStyle(
              color: Colors.grey.shade400,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Column(
              children: [
                Expanded(child: Row(children: [_corner('FL', fl), _corner('FR', fr)])),
                Expanded(child: Row(children: [_corner('RL', rl), _corner('RR', rr)])),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
