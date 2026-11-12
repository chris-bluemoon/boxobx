// Standalone test script to hear Gunther speak without running the full
// Flutter app or iOS Simulator UI. Exercises the exact same GroqService
// and TtsStreamingService classes used by VoiceEngine, saves the
// resulting Cartesia WAV audio to disk, and plays it via `afplay`.
//
// Run from the project root with:
//   dart run test_scripts/gunther_voice_test.dart "We're losing the gap to P2!"
//
// Requires a real .env with GROQ_API_KEY, TTS_API_KEY, TTS_PROVIDER,
// TTS_VOICE_ID already populated (see dashboard_screen.dart for how the
// real app loads these via flutter_dotenv).
import 'dart:io';

import 'package:boxbox/services/groq_service.dart';
import 'package:boxbox/services/tts_streaming_service.dart';
import 'package:boxbox/models/fused_race_state.dart';
import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/models/hud_overlay_data.dart';
import 'package:boxbox/models/sector_state.dart';
import 'package:boxbox/models/fuel_prediction.dart';

Map<String, String> _loadEnv(String path) {
  final file = File(path);
  final env = <String, String>{};
  if (!file.existsSync()) return env;
  for (final line in file.readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final splitIndex = trimmed.indexOf('=');
    if (splitIndex == -1) continue;
    env[trimmed.substring(0, splitIndex)] = trimmed.substring(splitIndex + 1);
  }
  return env;
}

Future<void> main(List<String> args) async {
  final env = _loadEnv('.env');
  final groqKey = env['GROQ_API_KEY'] ?? '';
  final ttsKey = env['TTS_API_KEY'] ?? '';
  final voiceId = env['TTS_VOICE_ID'] ?? '';
  final provider = env['TTS_PROVIDER'] ?? 'elevenlabs';

  if (groqKey.isEmpty || ttsKey.isEmpty || voiceId.isEmpty) {
    stderr.writeln('Missing GROQ_API_KEY / TTS_API_KEY / TTS_VOICE_ID in .env');
    exit(1);
  }

  final driverUtterance = args.isNotEmpty
      ? args.join(' ')
      : "What's my fuel looking like, and how far back is P3?";

  // A representative mid-race state so Gunther has something to react to.
  final raceState = FusedRaceState(
    telemetry: TelemetryFrame(
      rpm: 7200,
      speedKmh: 215,
      gear: 5,
      posX: 10,
      posY: 0,
      posZ: 1200,
      lapDistance: 1200,
      trackLength: 5891,
      fuelPercent: 8.5,
      tireTemps: [92, 94, 88, 89],
    ),
    hud: const HudOverlayData(
      gridPosition: 3,
      driverAhead: 'Verstappen',
      driverBehind: 'Hamilton',
      gapAheadSeconds: 1.2,
      gapBehindSeconds: 0.6,
    ),
    sectors: const SectorState(currentSectorIndex: 1, activeTrackName: 'Silverstone'),
    fuelPrediction: const FuelPrediction(predictedEmptyLap: 14, percentPerLap: 8.2, hasEnoughData: true),
  );

  print('Driver says: "$driverUtterance"');
  print('Sending to Groq...\n');

  final groq = GroqService(groqKey);
  final tts = TtsStreamingService(apiKey: ttsKey, voiceId: voiceId, provider: provider);

  await tts.connect();

  final audioBytes = <int>[];
  final ttsSub = tts.audioChunks.listen(audioBytes.addAll);

  final buffer = StringBuffer();
  await for (final token in groq.streamResponse(
    driverUtterance: driverUtterance,
    raceState: raceState,
  )) {
    stdout.write(token);
    buffer.write(token);
    tts.sendToken(token);
  }
  tts.flush();

  print('\n\nGunther said: "${buffer.toString().trim()}"');
  print('Waiting for completion signal from TTS provider...');

  // Wait for the provider's explicit completion signal (Cartesia's
  // done:true / ElevenLabs' isFinal:true) rather than guessing with a
  // fixed delay -- a fixed delay risked cutting off the tail end of the
  // audio on a slow/jittery connection (the real bug this was fixing).
  await tts.waitForCompletion();
  await Future.delayed(const Duration(milliseconds: 150));
  await ttsSub.cancel();
  await tts.disconnect();

  if (audioBytes.isEmpty) {
    stderr.writeln('No audio received from TTS provider.');
    exit(1);
  }

  final outputBytes = provider == 'cartesia'
      ? TtsStreamingService.wrapPcm16AsWav(audioBytes)
      : audioBytes;

  final outputPath = 'test_scripts/gunther_output.wav';
  await File(outputPath).writeAsBytes(outputBytes);
  print('Saved ${audioBytes.length} bytes to $outputPath');

  if (Platform.isMacOS) {
    print('Playing audio via afplay...');
    final result = await Process.run('afplay', [outputPath]);
    if (result.exitCode != 0) {
      stderr.writeln('afplay failed: ${result.stderr}');
    }
  } else {
    print('Open $outputPath manually to listen.');
  }
}
