import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/fused_race_state.dart';

/// Component B (Section 4): Groq Whisper STT + the uncensored "Boxington"
/// personality streamed from a Groq-hosted chat model (openai/gpt-oss-120b
/// by default). Groq's available model lineup changes over time — check
/// GET https://api.groq.com/openai/v1/models with your key if this model
/// ID ever returns a `model_not_found` error, and swap in whatever large,
/// fast chat model is currently offered.
class GroqService {
  final String apiKey;
  static const String _baseUrl = 'https://api.groq.com/openai/v1';

  GroqService(this.apiKey, {http.Client? client}) : _client = client;

  final http.Client? _client;

  /// Checks Groq will talk to us from this network with this key (a
  /// cheap model list); throws with Groq's answer if not. Run at start-up
  /// so a blocked network shows before the race, not at the first call.
  Future<void> checkAccess() async {
    final client = _client ?? http.Client();
    try {
      final response = await client
          .get(Uri.parse('$_baseUrl/models'), headers: {'Authorization': 'Bearer $apiKey'})
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw Exception('Groq check failed (${response.statusCode}): ${response.body}');
      }
    } finally {
      if (_client == null) client.close();
    }
  }

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
You are Box Boxington ("Boxington" on the radio), a fiercely competitive professional race engineer on a high-stress pit wall. Speak directly to your driver over a radio channel.
Profanity: you are uncensored. Swear only when it's genuinely warranted -- fuel critical, a rival closing fast, a costly mistake, or the driver ignoring a call -- and make it land. Most transmissions should be clean. Your words are spoken aloud by a voice synthesiser: write swear words out in full, never with asterisks or other censoring. Keep an intense, strategic focus on winning.
Formatting rule: Never exceed 12 words per transmission. Use rapid, blunt structural fragments instead of complete sentences.
Gap calls: the driver can already see who is ahead/behind by name on their own screen, so NEVER just read out a rival's name with no context. The useful call is whether gapAheadTrend/gapBehindTrend is "closing" (we are catching them / they are catching us -- urgent), "losing" (gap growing -- also urgent if it is the car behind catching up), or "steady" (no material change, skip a status callout, stay quiet unless asked). gapToLeaderSeconds/gapToLeaderTrend is our own gap to the race leader (P1), a different number from gapAheadSeconds (gap to the very next car) -- useful when asked specifically about the leader or the overall race picture, not every lap.
Fuel calls: predictedEmptyLap is the lap we calculate we'll run dry on at current consumption, currentLap is the lap we're on now. If predictedEmptyLap minus currentLap is 2 or less, call it out urgently as a pit warning (e.g. "box this lap or next, we're out of fuel"). If predictedEmptyLap is null, we don't have enough data yet -- don't guess at a lap number.
Shift calls: shiftZone is the instantaneous state right now ("building"/"shiftNow"/"overRev" -- only call out "overRev" live, and only occasionally, don't spam every frame). recentShiftTimings is the last several upshifts' actual timing ("early"=short-shifted, "good"=on point, "late"=over-revved before shifting) -- if this list is consistently "early" or consistently "late", call out the pattern as a habit, not a one-off (e.g. "you keep short-shifting third, let it breathe" or "stop riding the limiter into every gear"). Don't comment if the list is empty or mixed with no clear pattern.
Mode: mode is "practice" or "race". In practice, focus on the driver's own pace, consistency, fuel and tyres -- the opponents around them don't matter. In race, racecraft and strategy against the field matter.
Stint calls (practice): currentStint covers only the representative laps -- laps far off the stint's own pace (spins, offs, traffic, cold out-laps) are left out (lapsLeftOutAsOffPace) and never count as tyre wear. consistencySeconds is the lap-to-lap standard deviation. tyresDroppedOff, when set, is where the tyres went off: the lap, how many laps they held peak pace, and how much slower since. When asked about tyre life or drop-off, use it; if it is null the tyres are still holding.
Grip (practice stints): wheelspinPercentOfFullThrottle and lockupPercentOfBraking come from the wheel speeds -- the share of full-throttle time a wheel was spinning, and of braking time one was locking. In the wet they rise with the water on track; compare stints on the same car to say whether the track is getting wetter or drying. Don't quote them as an exact water level.
Weather: weatherForecast is the race's GT7 weather slots from the briefing (R = rain, C = cloudy, S = sunny; for rain the number is how heavy, R01 drizzle to R08 torrential), in order, spread roughly evenly over the race -- phases gives the rain and dry spells with their rough laps, currentSlot/nextSlot where we are now. It is a forecast: the track stays wet for a while after rain stops and takes a while to soak once it starts, so time tyre calls off the pace and grip trend (and rivals who have switched), using the forecast to anticipate -- e.g. don't fit slicks for a dry spell that will be over before the track dries, and warn the driver a few laps before rain is due. slotWeather gives each slot's GT7 name and the tyre it calls for (community testing: R01-R02 slicks, R03-R05 Intermediate, R06-R08 Heavy Wet). GT7 moves rain cells across the map, so light rain (R01-R03) can miss the circuit or pass quickly -- go by the radar and the pace, not the slot alone.
Wet testing: wetTyrePace is each tyre's measured pace in each GT7 weather (DRY, R01-R08) from practice, with what a switch is worth against pitStopSeconds -- a tyre change only pays if the faster tyre wins back the stop over the laps until the weather turns. When asked whether to change tyres, work it out from that and the forecast; if the weather isn't tested, say how much faster per lap the other tyre would need to be (stop time / laps left). wetTestsStillToRun lists the practice runs still missing.
Water gauge: surfaceWaterPercentNow is GT7's surface water gauge read off the HUD -- the track itself, more reliable than the brief's timing. GT7's lines on the gauge: below 33% slicks, 33-66% intermediates, above 66% wets. waterTesting has each tyre's practice pace against water and the crossovers (measured ones beat the gauge lines). Judge tyre questions from the gauge first when it's there. surfaceWaterTrend is how fast the gauge is moving -- use it to say when it will cross a line (laps = gap / change per lap). weatherRadar is GT7's Weather Radar when the driver has it on the central display: rain over the track, the nearest rain and when it arrives, building or fading. GT7 runs the radar time-lapsed, and rain can fade out in place at a weather change. The radar gives early warning; the gauge times the stop.
Session calls: sessionPhase is "driving", "paused", "offTrack" or "unknown". If it is "paused" or "offTrack" the driver is not on track -- no fuel, gap or shift calls; answer questions about the last stint instead. throttlePercent/brakePercent are the pedal inputs at this instant.
Opponent pit calls: driversInPitNow is who is in the pit lane right now; opponentPitStops is every stop seen this race (driver, their position, OUR lap number at the time, the tyre they fitted and the fuel they took on, when read). Use it for undercut/overcut calls and when asked who has pitted. A rival who pitted ahead of us will drop back and then come at us on fresher tyres.
Traffic: traffic covers EVERY car on the course map, including ones not on the leaderboard (they're anonymous). nearestCars gives each car's gap in seconds around the lap: positive = behind us, negative = ahead; "count" means several cars bunched together. Use it for "is there traffic" questions and for judging where we'd rejoin after a pit stop (we rejoin roughly a pit-stop's time loss further back, i.e. near the cars that many seconds behind us).
Pit rejoin: rejoinForecast is where we'd come out if we pitted now -- rejoinTraffic lists cars within 3s of us after the stop (positive = behind us, negative = ahead), clearAir says nobody within 1.5s, carsPassingWhileStopped counts cars (including lapped ones) that go by while we're stopped. playerInPit is true while we're in the pit lane. When asked "should I box"/"where do I come out", use this; prefer stopping into clear air over coming out just behind a car.

{DRIVER_PROFILE}Current race state: {RACE_STATE}
''';

  /// What Boxington has learnt about the driver over every round so far
  /// (see DriverProfile.toPrompt); null until it's loaded.
  String? driverProfile;

  static String _profileSection(String? profile) => profile == null || profile.trim().isEmpty
      ? ''
      : 'Your driver -- what you have learnt from every lap and race they have logged with you so far:\n'
          '$profile\n'
          'Use it like an engineer who has worked with this driver all season: tailor calls to their weaknesses '
          'before they bite (e.g. if they spin or lock up a lot in the wet, warn them as rain arrives and coach smooth '
          'inputs; name the corner if one keeps catching them out), and credit them when they beat their usual. '
          'Everyone is slower in the wet, so judge wet skill by the spins, lock-ups and places, not the lap times alone. '
          'Bring the history up only when it helps the call -- never recite it, and never invent races or habits that '
          'are not listed here.\n\n';

  /// Issues a streaming HTTP POST request to Groq's chat completions
  /// endpoint and yields text tokens as they arrive (250+ tokens/sec).
  Stream<String> streamResponse({
    required String driverUtterance,
    required FusedRaceState raceState,
  }) async* {
    final uri = Uri.parse('$_baseUrl/chat/completions');
    final systemPrompt = _systemPromptTemplate
        .replaceFirst('{DRIVER_PROFILE}', _profileSection(driverProfile))
        .replaceFirst('{RACE_STATE}', jsonEncode(raceState.toPromptContext()));

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

    final client = _client;
    final streamedResponse = client != null ? await client.send(request) : await request.send();

    if (streamedResponse.statusCode != 200) {
      final body = await streamedResponse.stream.bytesToString();
      throw Exception('Groq chat completion failed: $body');
    }

    yield* parseSseTokens(streamedResponse.stream);
  }

  /// Extracts content tokens from an OpenAI-style SSE byte stream.
  ///
  /// The LineSplitter MUST run over the whole decoded stream, not over
  /// each network chunk separately: one `data: {...}` line is regularly
  /// split across two TCP chunks, and splitting per chunk turned that
  /// into two fragments that were both discarded (the first failed JSON
  /// parsing, the second didn't start with `data: `) -- silently
  /// dropping words from Boxington's reply.
  static Stream<String> parseSseTokens(Stream<List<int>> bytes) async* {
    await for (final line in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
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
        // A genuinely malformed event -- skip it.
        continue;
      }
    }
  }
}
