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
/// PTT release -> Whisper STT -> streamed Llama "Boxington" response ->
/// streamed TTS audio -> playback through the headphone amp, with
/// native iOS auto-ducking engaged while Boxington is speaking.
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

  /// Callouts that arrived while Boxington was busy -- see
  /// ProactiveCalloutQueue and speakProactively.
  final ProactiveCalloutQueue _proactiveQueue;

  /// Supplies the freshest race state when a queued callout is finally
  /// spoken, so Boxington reacts to the race as it is now rather than to
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

  // --- Instant clips -------------------------------------------------------

  /// Fixed phrases synthesised once and kept as files, so they play the
  /// moment they're needed -- no AI model, no TTS round trip. For calls
  /// where a second's delay matters (the rejoin "wait... go").
  final Map<String, String> _clipFiles = {};

  /// Bumped whenever a clip cuts in: a reply that was still being
  /// generated, or playing, when it did is dropped.
  int _generation = 0;
  AudioPlayer? _currentPlayer;

  /// The TTS socket handles one utterance at a time; everything that
  /// uses it queues here.
  Future<void> _ttsTail = Future.value();

  Future<T> _withTts<T>(Future<T> Function() body) {
    final result = _ttsTail.then((_) => body());
    _ttsTail = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Synthesises [phrases] ahead of time (call once at start-up).
  Future<void> precacheClips(Iterable<String> phrases) async {
    for (final phrase in phrases) {
      try {
        await _clipFile(phrase);
      } catch (error) {
        debugPrint('VoiceEngine: could not cache "$phrase": $error');
      }
    }
  }

  Future<String?> _clipFile(String phrase) async {
    final cached = _clipFiles[phrase];
    if (cached != null) return cached;
    final bytes = await _withTts(() => _synthesize(phrase));
    if (bytes.isEmpty) return null;
    final isCartesia = ttsService.provider == 'cartesia';
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/boxington_clip_${phrase.hashCode.toUnsigned(32)}.${isCartesia ? 'wav' : 'mp3'}');
    await file.writeAsBytes(isCartesia ? TtsStreamingService.wrapPcm16AsWav(bytes) : bytes);
    return _clipFiles[phrase] = file.path;
  }

  Future<List<int>> _synthesize(String text) async {
    await ttsService.connect();
    final audioBytes = <int>[];
    final sub = ttsService.audioChunks.listen(audioBytes.addAll);
    try {
      ttsService.sendToken(text);
      ttsService.flush();
      await ttsService.waitForCompletion();
      await Future.delayed(const Duration(milliseconds: 150));
    } finally {
      await sub.cancel();
      await ttsService.disconnect();
    }
    return audioBytes;
  }

  /// Says [phrase] straight away, cutting off whatever Boxington is
  /// saying (or about to say). Uses the cached clip, synthesising it
  /// first if it isn't cached yet.
  Future<void> speakClip(String phrase) async {
    final generation = ++_generation;
    final interrupted = _currentPlayer;
    _currentPlayer = null;
    await interrupted?.stop();

    final String? path;
    try {
      path = await _clipFile(phrase);
    } catch (error) {
      debugPrint('VoiceEngine.speakClip failed: $error');
      return;
    }
    if (path == null || generation != _generation) return;

    _setStatus(VoiceEngineStatus.responding);
    await audioSession.setDucking(true);
    await _play(path, generation);
  }

  /// Plays a file to the end (or until a clip cuts in), then releases
  /// ducking and goes idle -- unless a clip has taken over meanwhile.
  Future<void> _play(String path, int generation) async {
    final player = AudioPlayer();
    _currentPlayer = player;
    try {
      await player.setFilePath(path);
      unawaited(player.play());
      // Wait for playback to actually finish (or be stopped by a clip)
      // before releasing ducking and resetting status, otherwise
      // Boxington's voice would be un-ducked/cut short mid-sentence.
      await player.playerStateStream.firstWhere(
        (state) =>
            state.processingState == ProcessingState.completed ||
            (state.processingState == ProcessingState.idle && _currentPlayer != player),
      );
    } finally {
      await player.dispose();
      if (_currentPlayer == player) _currentPlayer = null;
      if (generation == _generation) {
        await audioSession.setDucking(false);
        _setStatus(VoiceEngineStatus.idle);
      }
    }
  }

  Future<void> onPushToTalkPressed() async {
    _setStatus(VoiceEngineStatus.listening);
    await pushToTalk.startRecording();
  }

  /// Has Boxington speak up UNPROMPTED -- no push-to-talk, no Whisper
  /// transcription step -- triggered by the app detecting a sustained
  /// problem (e.g. a consistent short-shifting/over-revving habit; see
  /// ProactiveCoachTrigger) rather than the driver asking a question.
  ///
  /// [syntheticPrompt] is not shown to the driver or spoken aloud -- it
  /// stands in for "what the driver said" in Boxington's system prompt so
  /// the same streamResponse() plumbing can be reused, instructing him
  /// on what to proactively call out this time.
  ///
  /// If Boxington is already listening/mid-response, the callout is
  /// queued and spoken once he's idle again (unless it goes stale
  /// first -- see ProactiveCalloutQueue), so it never interrupts the
  /// driver's push-to-talk but isn't lost either.
  Future<void> speakProactively(String syntheticPrompt, FusedRaceState raceState) async {
    if (_status != VoiceEngineStatus.idle) {
      _proactiveQueue.add(syntheticPrompt);
      return;
    }
    try {
      await _streamBoxingtonResponse(syntheticPrompt, raceState);
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
      // Debug visibility: helps diagnose "Boxington's response seems
      // unrelated to what I said" reports, which are very often actually
      // Whisper mis-transcribing noisy/silent mic input (e.g. the iOS
      // Simulator's virtual mic) rather than Boxington reacting randomly.
      debugPrint('VoiceEngine: Whisper transcribed "$transcript"');
      _transcriptController.add(transcript);

      await _streamBoxingtonResponse(transcript, raceState);
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

  Future<void> _streamBoxingtonResponse(String utterance, FusedRaceState raceState) async {
    final generation = _generation;
    _setStatus(VoiceEngineStatus.responding);
    final path = await _withTts(() => _generateResponseAudio(utterance, raceState, generation));
    if (path == null) return;
    final file = File(path);
    try {
      await _play(path, generation);
    } finally {
      await file.delete().catchError((_) => file);
    }
  }

  /// Streams the reply through the AI model and TTS into a temp file;
  /// null if there's nothing to play (or a clip has cut in).
  Future<String?> _generateResponseAudio(String utterance, FusedRaceState raceState, int generation) async {
    await ttsService.connect();
    await audioSession.setDucking(true);

    // IMPORTANT: this is NOT truly incremental playback. The previous
    // implementation called player.setAudioSource()/play() immediately
    // while audio chunks were still arriving, racing against
    // _ChunkedAudioSource.request() (which internally buffers the whole
    // stream via .toList() before returning). That race meant playback
    // started against a source that hadn't finished loading yet, so
    // just_audio silently played nothing -- visible as the UI reaching
    // "BOXINGTON TALKING" with total silence. Collecting all bytes first,
    // writing them to a temp file, and only then loading+playing removes
    // the race entirely, at the cost of waiting for the full response
    // before any audio starts (acceptable for Boxington's <12-word
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
      // connection, cutting off the tail end of Boxington's line.
      await ttsService.waitForCompletion();
      // Tiny safety margin: some providers' completion signal can
      // arrive a beat before the very last audio chunk is fully
      // delivered over the socket.
      await Future.delayed(const Duration(milliseconds: 150));
    } finally {
      await ttsSub.cancel();
      await ttsService.disconnect();
    }

    // A clip cut in while this was being generated: it has the floor.
    if (generation != _generation) return null;

    if (audioBytes.isEmpty) {
      await audioSession.setDucking(false);
      _setStatus(VoiceEngineStatus.idle);
      return null;
    }

    final isCartesia = ttsService.provider == 'cartesia';
    final outputBytes =
        isCartesia ? TtsStreamingService.wrapPcm16AsWav(audioBytes) : audioBytes;
    final extension = isCartesia ? 'wav' : 'mp3';

    final dir = await getTemporaryDirectory();
    final outputFile = File(
      '${dir.path}/boxington_response_${DateTime.now().millisecondsSinceEpoch}.$extension',
    );
    await outputFile.writeAsBytes(outputBytes);
    return outputFile.path;
  }

  void dispose() {
    _transcriptController.close();
    _responseController.close();
    _statusController.close();
  }
}

