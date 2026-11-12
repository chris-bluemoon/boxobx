import 'package:flutter/material.dart';

import '../models/voice_engine_status.dart';

/// Status pill for the voice pipeline (idle/listening/processing/talking/error).
class VoiceStatusBadge extends StatelessWidget {
  final VoiceEngineStatus status;

  const VoiceStatusBadge({super.key, required this.status});

  Color get _dotColor {
    switch (status) {
      case VoiceEngineStatus.idle:
        return Colors.greenAccent;
      case VoiceEngineStatus.listening:
        return Colors.redAccent;
      case VoiceEngineStatus.transcribing:
        return Colors.amberAccent;
      case VoiceEngineStatus.responding:
        return Colors.lightBlueAccent;
      case VoiceEngineStatus.error:
        return Colors.red.shade900;
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
            'GUNTHER · ${status.label}',
            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
