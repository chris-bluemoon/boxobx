import 'package:flutter/services.dart';

/// Section 5: iOS System Hardware Overrides.
///
/// Thin wrapper over a native platform channel that configures
/// AVAudioSession with voiceChat mode + mixWithOthers + duckOthers +
/// defaultToSpeaker. Gunther's voice plays entirely independently of the
/// PS5 → Fosi K7 → headphones chain: it comes out of the iPad's own
/// built-in speaker (or a paired Bluetooth speaker/earbud), never routed
/// through the K7, so PS5 game audio quality is never affected.
class NativeAudioSessionService {
  static const MethodChannel _channel = MethodChannel('boxbox/audio_session');

  Future<void> configureForVoiceEngineer() async {
    await _channel.invokeMethod('configureVoiceChatSession');
  }

  /// Called the exact millisecond the AI engineer starts/stops speaking so
  /// native code can trigger/release the auto-ducking of other audio.
  Future<void> setDucking(bool active) async {
    await _channel.invokeMethod('setDucking', {'active': active});
  }
}
