import 'dart:async';

import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:just_audio/just_audio.dart';

/// Component A (Section 4): Push-to-Talk Audio Management.
///
/// Handles mic recording start/stop on hold-gesture, plays the local
/// "click-pshh" radio static latency mask the instant the user releases,
/// and returns the recorded file path for Whisper transcription.
class PushToTalkService {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _maskPlayer = AudioPlayer();
  String? _activeRecordingPath;

  Future<void> startRecording() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) return;

    final dir = await getTemporaryDirectory();
    _activeRecordingPath =
        '${dir.path}/ptt_${DateTime.now().millisecondsSinceEpoch}.wav';

    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1),
      path: _activeRecordingPath!,
    );
  }

  /// Stops the mic feed, immediately fires the radio static latency mask,
  /// and returns the path to the saved audio buffer for STT.
  Future<String?> stopRecordingAndMask() async {
    final path = await _recorder.stop();

    // Fire-and-forget: the latency mask must play instantly, not wait on I/O.
    unawaited(_playLatencyMask());

    return path ?? _activeRecordingPath;
  }

  Future<void> _playLatencyMask() async {
    try {
      await _maskPlayer.setAsset('assets/audio/click_pshh.mp3');
      await _maskPlayer.play();
    } catch (_) {
      // Non-fatal: mask is cosmetic, never block the transcription pipeline.
    }
  }

  Future<void> dispose() async {
    await _recorder.dispose();
    await _maskPlayer.dispose();
  }
}
