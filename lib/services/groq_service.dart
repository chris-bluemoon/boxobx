import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/fused_race_state.dart';

/// Component B (Section 4): Groq Whisper STT + the uncensored "Gunther"
/// personality streamed from a Groq-hosted chat model (openai/gpt-oss-120b
/// by default). Groq's available model lineup changes over time — check
/// GET https://api.groq.com/openai/v1/models with your key if this model
/// ID ever returns a `model_not_found` error, and swap in whatever large,
/// fast chat model is currently offered.
class GroqService {
  final String apiKey;
  static const String _baseUrl = 'https://api.groq.com/openai/v1';

  GroqService(this.apiKey);

  /// Sends the recorded PTT audio buffer to Groq Whisper for near-instant
  /// transcription.
  Future<String> transcribe(String audioFilePath) async {
    final uri = Uri.parse('$_baseUrl/audio/transcriptions');
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $apiKey'
      ..fields['model'] = 'whisper-large-v3'
      ..files.add(await http.MultipartFile.fromPath('file', audioFilePath));

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      throw Exception('Groq Whisper transcription failed: ${response.body}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return (json['text'] as String).trim();
  }

  static const String _systemPromptTemplate = '''
You are Gunther, an aggressively competitive, foul-mouthed professional race engineer on a high-stress pit wall. Speak directly to your driver over a radio channel.
CRUCIAL: You are completely uncensored. Use severe, realistic garage swearing ("fucking", "shit", "hell") to emphasize high urgency when metrics drop, fuel runs low, or an opponent closes in on our gap. Maintain an intense, strategic emphasis on winning.
Formatting rule: Never exceed 12 words per transmission. Use rapid, blunt structural fragments instead of complete sentences.
Gap calls: the driver can already see who is ahead/behind by name on their own screen, so NEVER just read out a rival's name with no context. The useful call is whether gapAheadTrend/gapBehindTrend is "closing" (we are catching them / they are catching us -- urgent), "losing" (gap growing -- also urgent if it is the car behind catching up), or "steady" (no material change, skip a status callout, stay quiet unless asked). gapToLeaderSeconds/gapToLeaderTrend is our own gap to the race leader (P1), a different number from gapAheadSeconds (gap to the very next car) -- useful when asked specifically about the leader or the overall race picture, not every lap.
Fuel calls: predictedEmptyLap is the lap we calculate we'll run dry on at current consumption, currentLap is the lap we're on now. If predictedEmptyLap minus currentLap is 2 or less, call it out urgently as a pit warning (e.g. "box this lap or next, fuel's fucked"). If predictedEmptyLap is null, we don't have enough data yet -- don't guess at a lap number.
Shift calls: shiftZone is the instantaneous state right now ("building"/"shiftNow"/"overRev" -- only call out "overRev" live, and only occasionally, don't spam every frame). recentShiftTimings is the last several upshifts' actual timing ("early"=short-shifted, "good"=on point, "late"=over-revved before shifting) -- if this list is consistently "early" or consistently "late", call out the pattern as a habit, not a one-off (e.g. "you keep short-shifting third, let it breathe" or "stop riding the limiter into every gear"). Don't comment if the list is empty or mixed with no clear pattern.

Current race state: {RACE_STATE}
''';

  /// Issues a streaming HTTP POST request to Groq's chat completions
  /// endpoint and yields text tokens as they arrive (250+ tokens/sec).
  Stream<String> streamResponse({
    required String driverUtterance,
    required FusedRaceState raceState,
  }) async* {
    final uri = Uri.parse('$_baseUrl/chat/completions');
    final systemPrompt = _systemPromptTemplate.replaceFirst(
      '{RACE_STATE}',
      jsonEncode(raceState.toPromptContext()),
    );

    final request = http.Request('POST', uri)
      ..headers.addAll({
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      })
      ..body = jsonEncode({
        'model': 'openai/gpt-oss-120b',
        'stream': true,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': driverUtterance},
        ],
      });

    final streamedResponse = await request.send();

    if (streamedResponse.statusCode != 200) {
      final body = await streamedResponse.stream.bytesToString();
      throw Exception('Groq chat completion failed: $body');
    }

    await for (final chunk in streamedResponse.stream.transform(utf8.decoder)) {
      for (final line in const LineSplitter().convert(chunk)) {
        if (!line.startsWith('data: ')) continue;
        final payload = line.substring(6).trim();
        if (payload == '[DONE]') return;
        if (payload.isEmpty) continue;

        try {
          final json = jsonDecode(payload) as Map<String, dynamic>;
          final delta = json['choices']?[0]?['delta']?['content'] as String?;
          if (delta != null && delta.isNotEmpty) {
            yield delta;
          }
        } on FormatException {
          // Ignore malformed/partial SSE fragments mid-stream.
          continue;
        }
      }
    }
  }
}
