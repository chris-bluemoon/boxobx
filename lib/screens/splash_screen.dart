import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../widgets/box_box_logo.dart';

/// Launch splash on black (matching the native launch screen): two tyres
/// roll in together from the left, like a car's wheels, and become the
/// O's of "BOX BOX" to a racing-engine sound, the letters
/// appear round them, then the tagline -- and a fade into [next].
class SplashScreen extends StatefulWidget {
  final WidgetBuilder next;

  /// Total time on screen before moving on: the 2 s animation, then the
  /// finished logo held for 2 s.
  final Duration duration;

  /// Plays the engine sound (off in tests, which have no audio plugin).
  final bool playSound;

  const SplashScreen({
    super.key,
    required this.next,
    this.duration = const Duration(milliseconds: 4000),
    this.playSound = true,
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  )..forward();
  Timer? _timer;
  AudioPlayer? _player;

  /// The engine sound as the tyres roll in (assets/audio/splash_v8_rev.m4a):
  /// 2.4 s of a throaty V8 revving, its big blips peaking as the tyres land
  /// -- cut from "v8 engine rev.wav" by overmedium,
  /// https://freesound.org/s/651534 (CC0: public domain, no attribution
  /// required).
  ///
  /// just_audio caches an asset by its path and never refreshes it, so a
  /// changed sound needs a new file name or devices keep the old one.
  static const _engineSound = 'assets/audio/splash_v8_rev.m4a';

  /// The wordmark's font size before any shrinking to fit the screen.
  static const double _size = 110;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.duration, _goNext);
    if (widget.playSound) _playEngine();
  }

  Future<void> _playEngine() async {
    try {
      final player = _player = AudioPlayer();
      await player.setAsset(_engineSound);
      if (!mounted) return;
      await player.play();
    } catch (error) {
      // No sound is no reason to hold up the app.
      debugPrint('Splash sound failed: $error');
    }
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
    _player?.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// [t] mapped onto 0-1 across the [start]-[end] part of the animation.
  double _phase(double t, double start, double end, [Curve curve = Curves.easeOutCubic]) =>
      curve.transform(((t - start) / (end - start)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    // Far enough to start both tyres off the left edge of the screen (the
    // wordmark is centred; the first O is about 1.3 font sizes left of
    // centre, the second about 0.6 right).
    final travel = MediaQuery.sizeOf(context).width / 2 + _size * 1.6;
    final radius = _size * BoxBoxWheelWordmark.tyreScale / 2;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = _controller.value;
            // Both together, at their final spacing -- like a car's two
            // wheels rolling in.
            final rolled = _phase(t, 0.0, 0.6);
            final offsets = [-travel * (1 - rolled), -travel * (1 - rolled)];
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              // Shrinks to fit a narrow screen.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: BoxBoxWheelWordmark(
                  size: _size,
                  tyreOffsets: offsets,
                  // Rolling, not sliding: turned by the distance still to go,
                  // so each tyre comes to rest upright.
                  tyreTurns: [for (final x in offsets) x / (2 * 3.141592653589793 * radius)],
                  letters: _phase(t, 0.5, 0.8),
                  taglineOpacity: _phase(t, 0.75, 1.0),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
