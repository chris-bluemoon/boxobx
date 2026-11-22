import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../widgets/box_box_logo.dart';

/// Launch splash on black (matching the native launch screen): the B's
/// and X's of "BOX BOX" fade in from black, then two tyres roll in
/// together from the left, like a car's wheels, and stop as its O's to a
/// pit stop's wheel guns, then the tagline -- and a fade into [next].
class SplashScreen extends StatefulWidget {
  final WidgetBuilder next;

  /// Total time on screen before moving on: the 2.6 s animation, then the
  /// finished logo held for 2 s (timed from the animation's first frame).
  final Duration duration;

  /// Plays the engine sound (off in tests, which have no audio plugin).
  final bool playSound;

  const SplashScreen({
    super.key,
    required this.next,
    this.duration = const Duration(milliseconds: 4600),
    this.playSound = true,
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  /// The animation, in order: the letters fade in, the tyres roll in,
  /// then the tagline.
  static const _lettersMs = 600, _rollMs = 1200, _taglineMs = 800;
  static const _totalMs = _lettersMs + _rollMs + _taglineMs;

  /// Each step's start and end, as shares of the animation.
  static const double _rollStart = _lettersMs / _totalMs;
  static const double _rollEnd = (_lettersMs + _rollMs) / _totalMs;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _totalMs),
  );
  Timer? _timer;

  /// When the splash was made, for the start-up timings in the log.
  final _made = Stopwatch()..start();

  /// A pit stop as the tyres roll in (assets/audio/splash_pitstop_sync.m4a):
  /// the driver's pitstop.wav from 1.92 s to 7 s, faded over the last
  /// 0.3 s -- cut so the wheel-gun whir (3.12 s into the wav) comes at
  /// [_rollMs] into it -- it starts as the tyres set off, so the whir
  /// comes as they come to rest.
  /// It runs on past the 4 s splash into the dashboard, so its player
  /// isn't the screen's: it's let go when the sound ends. Downloaded for
  /// this app's own use -- check its licence before the app is shared or
  /// published (the earlier CC0 one, splash_wheel_gun.m4a, is in git).
  ///
  /// just_audio caches an asset by its path and never refreshes it, so a
  /// changed sound needs a new file name or devices keep the old one.
  static const _wheelGunSound = 'assets/audio/splash_pitstop_sync.m4a';

  /// The wordmark's font size before any shrinking to fit the screen.
  static const double _size = 110;

  @override
  void initState() {
    super.initState();
    _controller
      ..addStatusListener(_onStatus)
      ..forward();
    if (widget.playSound) _playWheelGun();
    WidgetsBinding.instance.addPostFrameCallback((_) => debugPrint('Splash: first frame ${_made.elapsedMilliseconds} ms after start'));
  }

  /// The finished logo is held from the animation's end, not a set time
  /// from start-up: on the animation's clock, which only runs once frames
  /// are being drawn -- a slow start can't cut the splash short.
  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    final hold = widget.duration - const Duration(milliseconds: _totalMs);
    _timer = Timer(hold.isNegative ? Duration.zero : hold, _goNext);
  }

  Future<void> _playWheelGun() async {
    final player = AudioPlayer();
    try {
      final loading = Stopwatch()..start();
      await player.setAsset(_wheelGunSound);
      debugPrint('Splash: sound loaded in ${loading.elapsedMilliseconds} ms '
          '(animation at ${_controller.lastElapsedDuration?.inMilliseconds ?? 0} ms)');
      if (!mounted) {
        await player.dispose();
        return;
      }
      // The sound starts as the tyres set off: on the animation's clock
      // (from its first frame, which can be well after the splash is
      // made) -- waiting till then, or starting that far in if it loaded
      // late.
      final sinceRoll = (_controller.lastElapsedDuration ?? Duration.zero) - const Duration(milliseconds: _lettersMs);
      if (sinceRoll.isNegative) {
        await Future<void>.delayed(-sinceRoll);
        if (!mounted) {
          await player.dispose();
          return;
        }
      } else if (sinceRoll > const Duration(milliseconds: 30)) {
        await player.seek(sinceRoll);
      }
      // Let go once it has played (play() completes then) -- not when the
      // splash closes, so the sound plays out.
      await player.play();
      await player.dispose();
    } catch (error) {
      await player.dispose();
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
            final rolled = _phase(t, _rollStart, _rollEnd);
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
                  // From black, before the tyres.
                  letters: _phase(t, 0.0, _rollStart, Curves.easeIn),
                  taglineOpacity: _phase(t, _rollEnd, 1.0),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
