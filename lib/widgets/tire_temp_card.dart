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

  /// [FL, FR, RL, RR] remaining-grip percent (100 = fresh, 0 = fully
  /// worn), read directly off GT7's HUD tire-wear widget by the
  /// laptop OCR relay (see laptop_ocr/tire_wear_reader.py) -- null per
  /// wheel if that frame's reading wasn't confidently read (e.g. the
  /// HUD relay isn't running, or the widget isn't currently on
  /// screen). Shown as a secondary readout under each corner's
  /// temperature, since GT7's own telemetry packet has no tire-wear
  /// field at all -- this is the only source of real (not proxied)
  /// wear data in the app.
  final List<double?> tireWearPercents;

  const TireTempCard({
    super.key,
    required this.tireTemps,
    this.tireWearPercents = const [null, null, null, null],
  });

  static const double _coldThreshold = 70;
  static const double _hotThreshold = 95;

  // Mirrors GT7's own in-game wear-bar colour behaviour (see
  // tire_wear_reader.py's module docstring): comfortably fresh is
  // white/green, below the "wear cliff" bands amber then red as grip
  // falls off.
  static const double _wearWarningThreshold = 50;
  static const double _wearCriticalThreshold = 20;

  Color _colorFor(double tempC) {
    if (tempC <= 0) return Colors.grey.shade700;
    if (tempC < _coldThreshold) return Colors.lightBlueAccent;
    if (tempC > _hotThreshold) return Colors.redAccent;
    return Colors.greenAccent.shade400;
  }

  Color _wearColorFor(double? wearPercent) {
    if (wearPercent == null) return Colors.grey.shade600;
    if (wearPercent <= _wearCriticalThreshold) return Colors.redAccent;
    if (wearPercent <= _wearWarningThreshold) return Colors.amberAccent;
    return Colors.grey.shade200;
  }

  bool get _anyOverheating => tireTemps.any((t) => t > _hotThreshold);

  Widget _corner(String label, double tempC, double? wearPercent) {
    final color = _colorFor(tempC);
    // Two lines -- "FL 80°" over "WEAR 64%" -- rather than three
    // (label / temp / wear): on a real iPad the card is shorter than in
    // the simulator, and the FittedBox below scales each corner down to
    // fit, so every line saved keeps the label and wear readable. The
    // FittedBox still guarantees no overflow however tight it gets.
    return Expanded(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                SizedBox(
                  width: 34,
                  child: Text(
                    label,
                    style: TextStyle(
                      color: Colors.grey.shade400,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                Text(
                  tempC <= 0 ? '--' : '${tempC.toStringAsFixed(0)}°',
                  style: TextStyle(
                    color: color,
                    fontSize: 44,
                    fontWeight: FontWeight.bold,
                    height: 1.05,
                  ),
                ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  'WEAR ',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 0.5),
                ),
                Text(
                  wearPercent == null ? '--' : '${wearPercent.toStringAsFixed(0)}%',
                  style: TextStyle(
                    color: _wearColorFor(wearPercent),
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fl = tireTemps.isNotEmpty ? tireTemps[0] : 0.0;
    final fr = tireTemps.length > 1 ? tireTemps[1] : 0.0;
    final rl = tireTemps.length > 2 ? tireTemps[2] : 0.0;
    final rr = tireTemps.length > 3 ? tireTemps[3] : 0.0;

    final wearFl = tireWearPercents.isNotEmpty ? tireWearPercents[0] : null;
    final wearFr = tireWearPercents.length > 1 ? tireWearPercents[1] : null;
    final wearRl = tireWearPercents.length > 2 ? tireWearPercents[2] : null;
    final wearRr = tireWearPercents.length > 3 ? tireWearPercents[3] : null;

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
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'TYRES',
            style: TextStyle(
              color: Colors.grey.shade400,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: Row(children: [
                    _corner('FL', fl, wearFl),
                    _corner('FR', fr, wearFr),
                  ]),
                ),
                Expanded(
                  child: Row(children: [
                    _corner('RL', rl, wearRl),
                    _corner('RR', rr, wearRr),
                  ]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
