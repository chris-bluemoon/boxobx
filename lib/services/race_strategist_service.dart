import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/race_briefing.dart';
import '../models/race_strategy.dart';
import 'base_rates.dart';
import 'pit_stop_calculator.dart';
import 'wet_pace_table.dart';

/// Pre-race strategy planning: takes a weekly APRL driver briefing
/// (track, lap count, starting fuel, available tires, etc.) and
/// produces a recommended pit-stop plan.
///
/// The actual numbers (pit laps, tire compounds, assumed fuel burn) are
/// computed DETERMINISTICALLY by PitStopCalculator -- the same
/// briefing always produces the exact same plan. Groq is only used
/// afterward to phrase per-stop reasoning and an overall summary
/// explaining that already-fixed plan in natural language; it is never
/// asked to invent the pit laps or fuel math itself. (An earlier
/// version let the AI freely compute the whole plan each time, which
/// produced a different "guess" on every call since LLMs have no
/// built-in determinism and are inherently inconsistent at multi-step
/// arithmetic -- this redesign fixes that inconsistency.)
///
/// Deliberately separate from GroqService's streamResponse() -- that is
/// Boxington's live, low-latency, <12-word radio personality for
/// in-race callouts; this is a one-shot, structured-JSON strategic
/// write-up done before the race even starts, with a completely
/// different system prompt and response shape (not meant to be heard,
/// meant to be read and acted on).
class RaceStrategistService {
  final String apiKey;
  static const String _baseUrl = 'https://api.groq.com/openai/v1';

  RaceStrategistService(this.apiKey);

  static const String _systemPrompt = '''
You are a professional sim-racing race strategist. A deterministic pit-stop PLAN has already been computed for this Gran Turismo 7 race -- your job is ONLY to write a short, natural-language explanation of it. Do NOT change the pit laps, tire compounds, or fuel figures given to you; just explain them clearly.

Respond with ONLY a single JSON object (no markdown, no prose outside the JSON), with this exact shape:
{
  "pitStopReasoning": ["<one short sentence explaining pit stop 1>", "<one short sentence for pit stop 2, if any>", ...],
  "summary": "<2-3 sentence plain-English overview of the overall strategy>"
}

The pitStopReasoning array must have exactly as many entries as there are pit stops listed below, in the same order.

Computed plan: {PLAN}
If the briefing has weatherSlots (GT7 weather in race order: R = rain, C = cloudy, S = sunny) with rain, the plan's stops follow the weather (tyre changes where it turns wet or dry, refuelling at the same stops): explain them that way, and say the laps are estimates -- in the race the water gauge calls each stop.

Race briefing: {BRIEFING}
''';

  /// Computes the deterministic plan via PitStopCalculator, then asks
  /// Groq to phrase the reasoning/summary around it. If the Groq call
  /// fails for any reason, falls back to the calculator's own
  /// plain-English text (see PitStopCalculator) rather than throwing --
  /// a slightly blunter but numerically-correct strategy is better than
  /// no strategy at all.
  Future<RaceStrategy> generateStrategy(
    RaceBriefing briefing, {
    double? trackLengthMeters,
    double? measuredPercentPerLap,
    double? measuredPitStopTimeLossSeconds,
    WetPaceTable? wetPace,
    BaseRates baseRates = BaseRates.none,
  }) async {
    final plan = PitStopCalculator.calculate(
      briefing,
      trackLengthMeters: trackLengthMeters,
      measuredPercentPerLap: measuredPercentPerLap,
      measuredPitStopTimeLossSeconds: measuredPitStopTimeLossSeconds,
      wetPace: wetPace,
      baseRates: baseRates,
    );
    if (plan.pitStops.isEmpty) {
      // Nothing for the AI to add reasoning to beyond the summary
      // PitStopCalculator already generated.
      return plan;
    }

    try {
      return await _phrasePlan(plan, briefing);
    } catch (_) {
      return plan;
    }
  }

  Future<RaceStrategy> _phrasePlan(RaceStrategy plan, RaceBriefing briefing) async {
    final uri = Uri.parse('$_baseUrl/chat/completions');
    final prompt = _systemPrompt
        .replaceFirst('{PLAN}', jsonEncode(plan.toMap()))
        .replaceFirst('{BRIEFING}', jsonEncode(briefing.toMap()));

    final response = await http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': 'openai/gpt-oss-120b',
        'stream': false,
        'temperature': 0,
        'response_format': {'type': 'json_object'},
        'messages': [
          {'role': 'system', 'content': prompt},
          {
            'role': 'user',
            'content': 'Write the explanation for this computed pit strategy.',
          },
        ],
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Groq strategy phrasing failed: ${response.body}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final content = json['choices']?[0]?['message']?['content'] as String?;
    if (content == null || content.isEmpty) {
      throw Exception('Groq strategy phrasing returned no content');
    }

    final phrasing = jsonDecode(content) as Map<String, dynamic>;
    final reasoningList = (phrasing['pitStopReasoning'] as List?)?.cast<String>() ?? const [];
    final summary = phrasing['summary'] as String? ?? plan.summary;

    if (reasoningList.length != plan.pitStops.length) {
      // Mismatched shape -- keep the deterministic plan's own
      // reasoning text rather than risk misattributing explanations
      // to the wrong stop.
      return plan;
    }

    return RaceStrategy(
      pitStops: [
        for (var i = 0; i < plan.pitStops.length; i++)
          PlannedPitStop(
            lap: plan.pitStops[i].lap,
            tireCompound: plan.pitStops[i].tireCompound,
            reasoning: reasoningList[i],
          ),
      ],
      startingTireCompound: plan.startingTireCompound,
      summary: summary,
      assumedPercentPerLap: plan.assumedPercentPerLap,
      totalEstimatedTimeLossSeconds: plan.totalEstimatedTimeLossSeconds,
      pitStopTimeIsMeasured: plan.pitStopTimeIsMeasured,
      testsDone: plan.testsDone,
      testsPlanned: plan.testsPlanned,
      basis: plan.basis,
      fuelMap: plan.fuelMap,
    );
  }
}
