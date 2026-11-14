import 'package:flutter/material.dart';

/// Section 6: One of the four massive visual block cards on the
/// hyper-minimalist dashboard (Speed / Gear / Fuel / Position).
class TelemetryCard extends StatelessWidget {
  final String label;
  final String value;
  final bool alert;
  final Color baseColor;

  const TelemetryCard({
    super.key,
    required this.label,
    required this.value,
    this.alert = false,
    this.baseColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: alert ? Colors.red.shade900 : Colors.grey.shade900,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: alert ? Colors.redAccent : Colors.grey.shade800, width: 2),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.grey.shade400,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          // Shrinks with the tile so a short tile (e.g. landscape, under
          // the page header) never overflows.
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: TextStyle(color: alert ? Colors.white : baseColor, fontSize: 56, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
