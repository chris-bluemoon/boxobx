import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../models/fused_race_state.dart';
import '../models/voice_engine_status.dart';
import 'groq_service.dart';
import 'tts_streaming_service.dart';
import 'push_to_talk_service.dart';
import 'native_audio_session_service.dart';
import 'proactive_callout_queue.dart';

/// Orchestrates the full low-latency voice pipeline (Section 4):
/// PTT release -> Whisper STT -> streamed Llama "Gunther" response ->
/// streamed TTS audio -> playback through the headphone amp, with
/// native iOS auto-ducking engaged while Gunther is speaking.
class VoiceEngine {
  final PushToTalkService pushToTalk;
  final GroqService groqService;
  final TtsStreamingService ttsService;
  final NativeAudioSessionService audioSession;

  final _transcriptController = StreamController<String>.broadcast();
  final _responseController = StreamController<String>.broadcast();
  final _statusController = StreamController<VoiceEngineStatus>.broadcast();
  VoiceEngineStatus _status = VoiceEngineStatus.idle;

  Stream<String> get transcripts => _transcriptController.stream;
  Stream<String> get responseTokens => _responseController.stream;
  Stream<VoiceEngineStatus> get statusStream => _statusController.stream;
  VoiceEngineStatus get status => _status;

  /// Callouts that arrived while Gunther was busy -- see
  /// ProactiveCalloutQueue and speakProactively.
  final ProactiveCalloutQueue _proactiveQueue;

  /// Supplies the freshest race state when a queued callout is finally
  /// spoken, so Gunther reacts to the race as it is now rather than to
  /// the state captured when the callout was queued.
  FusedRaceState Function()? latestRaceState;

  void _setStatus(VoiceEngineStatus status) {
    _status = status;
    _statusController.add(status);
    if (status == VoiceEngineStatus.idle) {
      // Deferred so whatever just set idle finishes unwinding first.
      scheduleMicrotask(_speakNextQueued);
    }
  }

  VoiceEngine({
    required this.pushToTalk,
    required this.groqService,
    required this.ttsService,
    required this.audioSession,
    this.latestRaceState,
    ProactiveCalloutQueue? proactiveQueue,
  }) : _proactiveQueue = proactiveQueue ?? ProactiveCalloutQueue();

  void _speakNextQueued() {
    if (_status != VoiceEngineStatus.idle) return;
    final prompt = _proactiveQueue.takeNext();
    final state = latestRaceState?.call();
    if (prompt == null || state == null) return;
    speakProactively(prompt, state);
  }

  /// Drops any callouts still waiting to be spoken -- call alongside a
  /// manual session reset so nothing from the previous race is heard.
  void clearQueuedCallouts() => _proactiveQueue.clear();

  Future<void> initialize() async {
    await audioSession.configureForVoiceEngineer();
  }

  Future<void> onPushToTalkPressed() async {
    _setStatus(VoiceEngineStatus.listening);
    await pushToTalk.startRecording();
  }

  /// Has Gunther speak up UNPROMPTED -- no push-to-talk, no Whisper
  /// transcription step -- triggered by the app detecting a sustained
  /// problem (e.g. a consistent short-shifting/over-revving habit; see
  /// ProactiveCoachTrigger) rather than the driver asking a question.
  ///
  /// [syntheticPrompt] is not shown to the driver or spoken aloud -- it
  /// stands in for "what the driver said" in Gunther's system prompt so
  /// the same streamResponse() plumbing can be reused, instructing him
  /// on what to proactively call out this time.
  ///
  /// If Gunther is already listening/mid-response, the callout is
  /// queued and spoken once he's idle again (unless it goes stale
  /// first -- see ProactiveCalloutQueue), so it never interrupts the
  /// driver's push-to-talk but isn't lost either.
  Future<void> speakProactively(String syntheticPrompt, FusedRaceState raceState) async {
    if (_status != VoiceEngineStatus.idle) {
      _proactiveQueue.add(syntheticPrompt);
      return;
    }
    try {
      await _streamGuntherResponse(syntheticPrompt, raceState);
    } catch (error, stackTrace) {
      debugPrint('VoiceEngine.speakProactively failed: $error\n$stackTrace');
      _setStatus(VoiceEngineStatus.error);
      Timer(const Duration(seconds: 2), () => _setStatus(VoiceEngineStatus.idle));
    }
  }

  Future<void> onPushToTalkReleased(FusedRaceState raceState) async {
    final audioPath = await pushToTalk.stopRecordingAndMask();
    if (audioPath == null) {
      _setStatus(VoiceEngineStatus.idle);
      return;
    }

    try {
      _setStatus(VoiceEngineStatus.transcribing);
      final transcript = await groqService.transcribe(audioPath);
      // Debug visibility: helps diagnose "Gunther's response seems
      // unrelated to what I said" reports, which are very often actually
      // Whisper mis-transcribing noisy/silent mic input (e.g. the iOS
      // Simulator's virtual mic) rather than Gunther reacting randomly.
      debugPrint('VoiceEngine: Whisper transcribed "$transcript"');
      _transcriptController.add(transcript);

      await _streamGuntherResponse(transcript, raceState);
    } catch (error, stackTrace) {
      // Previously swallowed completely silently -- any failure here
      // (bad API key, network drop, TTS error) would just show the
      // ERROR badge for 2s with zero information in the console, making
      // it impossible to diagnose. debugPrint at least surfaces it in
      // `flutter run`/`flutter logs` output.
      debugPrint('VoiceEngine.onPushToTalkReleased failed: $error\n$stackTrace');
      _setStatus(VoiceEngineStatus.error);
      Timer(const Duration(seconds: 2), () => _setStatus(VoiceEngineStatus.idle));
    }
  }

  Future<void> _streamGuntherResponse(String utterance, FusedRaceState raceState) async {
    _setStatus(VoiceEngineStatus.responding);
    await ttsService.connect();
    await audioSession.setDucking(true);

    // IMPORTANT: this is NOT truly incremental playback. The previous
    // implementation called player.setAudioSource()/play() immediately
    // while audio chunks were still arriving, racing against
    // _ChunkedAudioSource.request() (which internally buffers the whole
    // stream via .toList() before returning). That race meant playback
    // started against a source that hadn't finished loading yet, so
    // just_audio silently played nothing -- visible as the UI reaching
    // "GUNTHER TALKING" with total silence. Collecting all bytes first,
    // writing them to a temp file, and only then loading+playing removes
    // the race entirely, at the cost of waiting for the full response
    // before any audio starts (acceptable for Gunther's <12-word
    // transmissions, which only take ~1-4s to fully synthesize anyway).
    final audioBytes = <int>[];
    final ttsSub = ttsService.audioChunks.listen(audioBytes.addAll);

    try {
      await for (final token in groqService.streamResponse(
        driverUtterance: utterance,
        raceState: raceState,
      )) {
        _responseController.add(token);
        ttsService.sendToken(token);
      }
      ttsService.flush();

      // Wait for the TTS provider to explicitly signal it has sent all
      // audio for this utterance (Cartesia's done:true / ElevenLabs'
      // isFinal:true), rather than guessing with a fixed delay -- a
      // fixed delay was occasionally too short on a slow/jittery
      // connection, cutting off the tail end of Gunther's line.
      await ttsService.waitForCompletion();
      // Tiny safety margin: some providers' completion signal can
      // arrive a beat before the very last audio chunk is fully
      // delivered over the socket.
      await Future.delayed(const Duration(milliseconds: 150));
    } finally {
      await ttsSub.cancel();
      await ttsService.disconnect();
    }

    if (audioBytes.isEmpty) {
      await audioSession.setDucking(false);
      _setStatus(VoiceEngineStatus.idle);
      return;
    }

    final isCartesia = ttsService.provider == 'cartesia';
    final outputBytes =
        isCartesia ? TtsStreamingService.wrapPcm16AsWav(audioBytes) : audioBytes;
    final extension = isCartesia ? 'wav' : 'mp3';

    final dir = await getTemporaryDirectory();
    final outputFile = File(
      '${dir.path}/gunther_response_${DateTime.now().millisecondsSinceEpoch}.$extension',
    );
    await outputFile.writeAsBytes(outputBytes);

    final player = AudioPlayer();
    try {
      await player.setFilePath(outputFile.path);
      await player.play();
      // Wait for playback to actually finish before releasing ducking
      // and resetting status, otherwise Gunther's voice would be
      // un-ducked/cut short mid-sentence.
      await player.playerStateStream.firstWhere(
        (state) => state.processingState == ProcessingState.completed,
      );
    } finally {
      await player.dispose();
      await outputFile.delete().catchError((_) => outputFile);
      await audioSession.setDucking(false);
      _setStatus(VoiceEngineStatus.idle);
    }
  }

  void dispose() {
    _transcriptController.close();
    _responseController.close();
    _statusController.close();
  }
}

