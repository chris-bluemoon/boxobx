import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/box_box_logo.dart';

/// Launch splash: the Box Box logo animating in on black (matching the
/// native launch screen), then a fade into [next].
class SplashScreen extends StatefulWidget {
  final WidgetBuilder next;

  /// Total time on screen before moving on.
  final Duration duration;

  const SplashScreen({super.key, required this.next, this.duration = const Duration(milliseconds: 2200)});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..forward();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.duration, _goNext);
  }

  void _goNext() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 500),
        pageBuilder: (context, _, _) => widget.next(context),
        transitionsBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// [t] mapped onto 0-1 across the [start]-[end] part of the animation.
  double _phase(double t, double start, double end, [Curve curve = Curves.easeOutCubic]) =>
      curve.transform(((t - start) / (end - start)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = _controller.value;
            final logoIn = _phase(t, 0.0, 0.45);
            return Opacity(
              opacity: logoIn,
              child: Transform.translate(
                offset: Offset((1 - logoIn) * -60, 0),
                child: BoxBoxLogo(
                  size: 110,
                  // Tyres spin up and settle as the wordmark slides in.
                  tyreTurns: (1 - _phase(t, 0.0, 0.7, Curves.easeOutQuart)) * -1.5,
                  stripe: _phase(t, 0.35, 0.8),
                  taglineOpacity: _phase(t, 0.65, 1.0),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
