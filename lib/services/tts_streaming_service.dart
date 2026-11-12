import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Component B (Section 4): Persistent streaming TTS over WebSocket.
///
/// Supports either ElevenLabs or Cartesia.ai streaming endpoints. Text
/// tokens are piped in word-by-word as they arrive from Groq, and audio
/// chunks stream back with sub-200ms processing lag.
class TtsStreamingService {
  final String apiKey;
  final String voiceId;
  final String provider; // 'elevenlabs' | 'cartesia'

  /// Cartesia API version pinned for this integration. See
  /// https://docs.cartesia.ai for the latest supported version string.
  static const String _cartesiaVersion = '2026-08-14';

  WebSocketChannel? _channel;
  StreamController<List<int>>? _audioChunkController;
  String? _cartesiaContextId;
  Completer<void>? _doneCompleter;

  /// Cartesia sends a response (ending with its own `done: true`) for
  /// EACH individual sendToken()/flush() request sent on a context_id --
  /// that `done` marks only THAT request's generation as finished, not
  /// the whole utterance. Requests are sent back-to-back with no wait
  /// between them, so their `done` responses can arrive back over the
  /// network in any order -- in particular, an earlier word's `done` can
  /// easily arrive AFTER flush() has already been sent, since network
  /// timing is not guaranteed to match send order. Checking only "has
  /// flush() been called" was therefore still a race: it could resolve
  /// completion on an early token's `done`, dropping the rest of the
  /// sentence's audio (audible as "only the first syllable" plays).
  ///
  /// The reliable fix is to count: every sendToken()/flush() call
  /// increments [_requestsSent]; every `done: true` response increments
  /// [_responsesReceived]. Only once every single request we sent has
  /// had its own response come back -- counts equal, AND flush() has
  /// been called so we know the total is final -- do we know the very
  /// last (flush) request's audio has actually arrived.
  bool _finalFlushSent = false;
  int _requestsSent = 0;
  int _responsesReceived = 0;

  TtsStreamingService({
    required this.apiKey,
    required this.voiceId,
    this.provider = 'elevenlabs',
  });

  Stream<List<int>> get audioChunks => _audioChunkController!.stream;

  Future<void> connect() async {
    _audioChunkController = StreamController<List<int>>.broadcast();
    _cartesiaContextId = _generateContextId();
    _doneCompleter = Completer<void>();
    _finalFlushSent = false;
    _requestsSent = 0;
    _responsesReceived = 0;

    final uri = provider == 'cartesia'
        ? Uri.parse(
            'wss://api.cartesia.ai/tts/websocket?api_key=$apiKey&cartesia_version=$_cartesiaVersion')
        : Uri.parse(
            'wss://api.elevenlabs.io/v1/text-to-speech/$voiceId/stream-input?model_id=eleven_turbo_v2&api_key=$apiKey');

    _channel = WebSocketChannel.connect(uri);

    if (provider == 'elevenlabs') {
      _channel!.sink.add(jsonEncode({
        'text': ' ',
        'voice_settings': {'stability': 0.4, 'similarity_boost': 0.8},
        'xi_api_key': apiKey,
      }));
    }

    _channel!.stream.listen((message) {
      final decoded = jsonDecode(message as String) as Map<String, dynamic>;

      if (provider == 'cartesia') {
        _handleCartesiaMessage(decoded);
      } else {
        final audioBase64 = decoded['audio'] as String?;
        if (audioBase64 != null) {
          _audioChunkController?.add(base64Decode(audioBase64));
        }
        // ElevenLabs signals the end of the stream with isFinal: true on
        // the final message (may carry no audio of its own).
        if (decoded['isFinal'] == true) {
          _responsesReceived++;
          _maybeCompleteIfFullyDone();
        }
      }
    }, onError: (error) {
      // A dropped/errored socket should not leave the caller waiting on
      // waitForCompletion() forever -- resolve it so playback can still
      // proceed with whatever audio arrived before the drop, rather than
      // hanging indefinitely.
      if (!(_doneCompleter?.isCompleted ?? true)) {
        _doneCompleter?.complete();
      }
    }, onDone: () {
      if (!(_doneCompleter?.isCompleted ?? true)) {
        _doneCompleter?.complete();
      }
    });
  }

  void _handleCartesiaMessage(Map<String, dynamic> message) {
    switch (message['type']) {
      case 'chunk':
        final audioBase64 = message['data'] as String?;
        if (audioBase64 != null) {
          _audioChunkController?.add(base64Decode(audioBase64));
        }
        if (message['done'] == true) {
          _responsesReceived++;
          _maybeCompleteIfFullyDone();
        }
        break;
      case 'error':
        // Non-fatal from the caller's perspective; surfaced via the
        // underlying WebSocket error stream for logging if needed. Still
        // counts as "a response came back" so completion tracking stays
        // accurate even if this particular request errored out instead
        // of producing audio.
        _responsesReceived++;
        _maybeCompleteIfFullyDone();
        break;
      case 'done':
      default:
        if (message['done'] == true) {
          _responsesReceived++;
          _maybeCompleteIfFullyDone();
        }
        break;
    }
  }

  /// Resolves [_doneCompleter] only once (a) flush() has actually been
  /// called, so we know the total request count is final, and (b) every
  /// single request we sent has had its own `done`/`isFinal` response
  /// come back -- see the doc comment on [_finalFlushSent] for why a
  /// simpler "has flush been called" check was still racy.
  void _maybeCompleteIfFullyDone() {
    if (_finalFlushSent &&
        _responsesReceived >= _requestsSent &&
        !(_doneCompleter?.isCompleted ?? true)) {
      _doneCompleter?.complete();
    }
  }

  /// Resolves once the TTS provider has signaled that all audio for the
  /// current utterance has been sent (Cartesia's `done: true` flag, or
  /// ElevenLabs' `isFinal: true`), instead of guessing with a fixed
  /// delay after flush() -- which could either cut off trailing audio on
  /// a slow/jittery connection, or waste time waiting past when the
  /// audio actually finished arriving.
  Future<void> waitForCompletion({Duration timeout = const Duration(seconds: 10)}) {
    final completer = _doneCompleter;
    if (completer == null) return Future.value();
    return completer.future.timeout(timeout, onTimeout: () {
      // Safety net: if the provider never sends a completion signal for
      // some reason, don't hang forever -- fall back to proceeding with
      // whatever audio has arrived so far.
    });
  }

  String _generateContextId() {
    final random = Random();
    return List.generate(16, (_) => random.nextInt(16).toRadixString(16)).join();
  }

  /// Pipes a streamed text token straight through to the open TTS socket
  /// so partial sentences can start producing audio immediately.
  void sendToken(String token) {
    _requestsSent++;
    if (provider == 'cartesia') {
      _channel?.sink.add(jsonEncode({
        // Cartesia sunsets older model versions over time; 'sonic-latest'
        // always points at their current recommended fast TTS model. If
        // this starts erroring with "model_sunsetted", check
        // https://docs.cartesia.ai for the currently supported model_id.
        'model_id': 'sonic-latest',
        'transcript': token,
        'voice': {'mode': 'id', 'id': voiceId},
        // Cartesia's realtime WebSocket endpoint only supports the 'raw'
        // container (no WAV/MP3 framing) — the raw PCM bytes are wrapped
        // in a WAV header client-side before playback, see
        // wavHeaderFor() below / voice_engine.dart.
        'output_format': {
          'container': 'raw',
          'encoding': 'pcm_s16le',
          'sample_rate': 44100,
        },
        'language': 'en',
        'context_id': _cartesiaContextId,
        // 'continue: true' tells Cartesia "more transcript is coming for
        // this context_id, don't finalize/close it yet." This must be
        // true for every token except the final flush() call, otherwise
        // Cartesia synthesizes only the first token and immediately
        // closes the context (audible as playback cutting off almost
        // instantly after the first syllable).
        'continue': true,
      }));
    } else {
      _channel?.sink.add(jsonEncode({'text': token, 'try_trigger_generation': true}));
    }
  }

  /// Signals end-of-utterance so the TTS engine flushes any buffered audio.
  void flush() {
    // NOTE: deliberately NOT incrementing _requestsSent here. flush()'s
    // empty-transcript request exists purely to signal "no more real
    // tokens are coming" to Cartesia/ElevenLabs -- it's not guaranteed
    // to produce its own distinct done/isFinal response (an empty
    // transcript may have nothing to synthesize), so counting it as a
    // request we must see a matching response for would risk
    // _responsesReceived never catching up and waitForCompletion()
    // always hitting its timeout. The real completion condition is:
    // every actual sendToken() has its response back, AND flush() has
    // been called (so we know no more tokens will arrive afterwards).
    _finalFlushSent = true;
    // A response that arrives for a request already counted might push
    // _responsesReceived to equal _requestsSent right as flush() is
    // called -- re-check here in case the flag flip is what was
    // blocking completion.
    _maybeCompleteIfFullyDone();
    if (provider == 'cartesia') {
      _channel?.sink.add(jsonEncode({
        'context_id': _cartesiaContextId,
        'transcript': '',
        'continue': false,
      }));
    } else {
      _channel?.sink.add(jsonEncode({'text': ''}));
    }
  }

  Future<void> disconnect() async {
    await _channel?.sink.close();
    await _audioChunkController?.close();
    _channel = null;
    _audioChunkController = null;
  }

  /// Cartesia's realtime WebSocket only emits raw headerless PCM16 bytes
  /// (see [sendToken]'s `output_format`). Wrap them in a minimal 44-byte
  /// WAV header so any standard audio player (just_audio, afplay, etc.)
  /// can interpret the byte stream correctly.
  static List<int> wrapPcm16AsWav(
    List<int> pcmBytes, {
    int sampleRate = 44100,
    int numChannels = 1,
  }) {
    final byteRate = sampleRate * numChannels * 2;
    final blockAlign = numChannels * 2;
    final dataLength = pcmBytes.length;
    final header = <int>[
      ...ascii('RIFF'),
      ..._uint32le(36 + dataLength),
      ...ascii('WAVE'),
      ...ascii('fmt '),
      ..._uint32le(16), // PCM fmt chunk size
      ..._uint16le(1), // audio format: PCM
      ..._uint16le(numChannels),
      ..._uint32le(sampleRate),
      ..._uint32le(byteRate),
      ..._uint16le(blockAlign),
      ..._uint16le(16), // bits per sample
      ...ascii('data'),
      ..._uint32le(dataLength),
    ];
    return [...header, ...pcmBytes];
  }

  static List<int> ascii(String s) => s.codeUnits;
  static List<int> _uint16le(int v) => [v & 0xFF, (v >> 8) & 0xFF];
  static List<int> _uint32le(int v) =>
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
}
