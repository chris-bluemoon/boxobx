import 'package:flutter/material.dart';

import '../models/connection_status.dart';

/// Small pill-shaped indicator used in the connection status bar to show
/// whether a given component (telemetry, HUD OCR, voice engine) is
/// currently live, connecting, stale, or disconnected.
class StatusBadge extends StatelessWidget {
  final String label;
  final ConnectionStatus status;

  const StatusBadge({super.key, required this.label, required this.status});

  Color get _dotColor {
    switch (status) {
      case ConnectionStatus.live:
        return Colors.greenAccent;
      case ConnectionStatus.connecting:
        return Colors.amberAccent;
      case ConnectionStatus.stale:
        return Colors.orangeAccent;
      case ConnectionStatus.disconnected:
        return Colors.grey.shade600;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.shade800),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: _dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            '$label · ${status.label}',
            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
