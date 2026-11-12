import 'package:flutter/material.dart';

/// Section 6: massive screen-half target button mapping onto the
/// Push-to-Talk execution triggers.
class PushToTalkButton extends StatefulWidget {
  final VoidCallback onPressStart;
  final VoidCallback onPressEnd;

  const PushToTalkButton({
    super.key,
    required this.onPressStart,
    required this.onPressEnd,
  });

  @override
  State<PushToTalkButton> createState() => _PushToTalkButtonState();
}

class _PushToTalkButtonState extends State<PushToTalkButton> {
  bool _isHeld = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        setState(() => _isHeld = true);
        widget.onPressStart();
      },
      onTapUp: (_) {
        setState(() => _isHeld = false);
        widget.onPressEnd();
      },
      onTapCancel: () {
        setState(() => _isHeld = false);
        widget.onPressEnd();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: double.infinity,
        decoration: BoxDecoration(
          color: _isHeld ? Colors.red.shade700 : Colors.grey.shade900,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Center(
          child: Text(
            _isHeld ? 'TRANSMITTING…' : 'HOLD TO TALK',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}
